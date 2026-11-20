package main

import (
	"context"
	"errors"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/platform"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/segmentio/kafka-go"
	"log"
	"net/http"
	"sync"
	"sync/atomic"
	"time"
)

type counters struct{ stored, alerts atomic.Int64 }

func consume(ctx context.Context, pool *pgxpool.Pool, counts *counters) {
	r := kafka.NewReader(kafka.ReaderConfig{Brokers: platform.Brokers(), Topic: "auth.journal", GroupID: "cases", MinBytes: 1, MaxBytes: 10e6, MaxWait: 10 * time.Millisecond, CommitInterval: 0})
	defer r.Close()
	for ctx.Err() == nil {
		messages := make([]kafka.Message, 0, 500)
		first, err := r.FetchMessage(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			log.Printf("Kafka unavailable, retrying: %v", err)
			platform.Sleep(ctx, 2*time.Second)
			continue
		}
		messages = append(messages, first)
		batchCtx, cancel := context.WithTimeout(ctx, 200*time.Millisecond)
		for len(messages) < 500 {
			m, err := r.FetchMessage(batchCtx)
			if err != nil {
				if !errors.Is(err, context.DeadlineExceeded) && ctx.Err() == nil {
					log.Printf("Kafka batch read interrupted: %v", err)
				}
				break
			}
			messages = append(messages, m)
		}
		cancel()
		backoff := 100 * time.Millisecond
		lastLog := time.Time{}
		for ctx.Err() == nil {
			dbCtx, stop := context.WithTimeout(ctx, 5*time.Second)
			n, a, err := store(dbCtx, pool, messages)
			stop()
			if err == nil {
				counts.stored.Add(n)
				counts.alerts.Add(a)
				break
			}
			if time.Since(lastLog) >= 2*time.Second {
				log.Printf("database unavailable, holding %d messages, retrying: %v", len(messages), err)
				lastLog = time.Now()
			}
			pool.Reset()
			if !platform.Sleep(ctx, backoff) {
				return
			}
			backoff = min(2*time.Second, backoff*2)
		}
		if ctx.Err() != nil {
			return
		}
		for {
			if err := r.CommitMessages(ctx, messages...); err == nil {
				break
			} else if ctx.Err() != nil {
				return
			} else {
				log.Printf("Kafka commit unavailable, holding %d messages, retrying: %v", len(messages), err)
			}
			if !platform.Sleep(ctx, 2*time.Second) {
				return
			}
		}
	}
}
func main() {
	ctx, cancel := platform.Context()
	defer cancel()
	if len(platform.Brokers()) == 0 || platform.Env("PG_URL", "") == "" {
		log.Print("KAFKA_BOOTSTRAP and PG_URL are required")
		return
	}
	config, err := pgxpool.ParseConfig(platform.Env("PG_URL", ""))
	if err != nil {
		log.Print("invalid PG_URL")
		return
	}
	config.ConnConfig.ConnectTimeout = 2 * time.Second
	config.MaxConns = int32(max(4, platform.Int("EXPLAINER_WORKERS", 2)+2))
	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		log.Printf("database pool failed: %v", err)
		return
	}
	defer pool.Close()
	var counts counters
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			c, stop := context.WithTimeout(ctx, 5*time.Second)
			_, err := pool.Exec(c, schema)
			stop()
			if err == nil {
				break
			}
			if ctx.Err() != nil {
				return
			}
			log.Printf("database unavailable, waiting to create schema: %v", err)
			pool.Reset()
			if !platform.Sleep(ctx, 2*time.Second) {
				return
			}
		}
		if url := platform.Env("EXPLAINER_URL", ""); url != "" {
			for i := 0; i < max(1, platform.Int("EXPLAINER_WORKERS", 2)); i++ {
				wg.Add(1)
				go func() { defer wg.Done(); explain(ctx, pool, url) }()
			}
		}
		consume(ctx, pool, &counts)
	}()
	wg.Add(1)
	go func() {
		defer wg.Done()
		var prevN, prevA int64
		for platform.Sleep(ctx, 5*time.Second) {
			n, a := counts.stored.Load(), counts.alerts.Load()
			c, stop := context.WithTimeout(ctx, 2*time.Second)
			lag, _, err := platform.KafkaLag(c, "cases", "auth.journal")
			stop()
			if err != nil {
				log.Printf("5s: stored %d transactions, %d alerts, lag unavailable", n-prevN, a-prevA)
			} else {
				log.Printf("5s: stored %d transactions, %d alerts, lag %d", n-prevN, a-prevA, lag)
			}
			prevN, prevA = n, a
		}
	}()
	mux := http.NewServeMux()
	platform.Health(mux)
	platform.Serve(ctx, platform.Env("LISTEN", ":9092"), mux)
	cancel()
	wg.Wait()
}
