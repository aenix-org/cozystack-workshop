package main

import (
	"context"
	"encoding/json"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/metrics"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/model"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/platform"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/scoring"
	"github.com/redis/go-redis/v9"
	"log"
	"math"
	"net/http"
	"time"
)

var workSink float64

func busy(d time.Duration) {
	end := time.Now().Add(d)
	v := 1.0
	for time.Now().Before(end) {
		for i := 0; i < 1000; i++ {
			v = math.Sqrt(v + float64(i))
		}
	}
	workSink = v
}
func run(ctx context.Context, stats *metrics.Stats) {
	r := platform.Reader("auth.requests", "scorer")
	defer r.Close()
	w := platform.Writer("auth.decisions")
	defer w.Close()
	client := redis.NewClient(&redis.Options{Addr: platform.Env("REDIS_ADDR", "localhost:6379"), Password: platform.Env("REDIS_PASSWORD", ""), DialTimeout: 2 * time.Second, ReadTimeout: 2 * time.Second, WriteTimeout: 2 * time.Second})
	defer client.Close()
	for {
		m, err := r.FetchMessage(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			log.Printf("Kafka unavailable: %v", err)
			if !platform.Sleep(ctx, 2*time.Second) {
				return
			}
			continue
		}
		var req model.AuthRequest
		if err := json.Unmarshal(m.Value, &req); err != nil {
			log.Print("invalid authorization message, skipping")
			_ = r.CommitMessages(ctx, m)
			continue
		}
		start := time.Now()
		var f scoring.Features
		for {
			f, err = scoring.Fetch(ctx, client, req)
			if err == nil {
				break
			}
			if ctx.Err() != nil {
				return
			}
			log.Printf("Redis unavailable, holding transaction: %v", err)
			if !platform.Sleep(ctx, 2*time.Second) {
				return
			}
		}
		busy(time.Duration(platform.Int("WORK_MS", 3)) * time.Millisecond)
		d := scoring.Score(req, f, platform.Float("THRESHOLD", .8))
		d.ScorerMS = float64(time.Since(start)) / float64(time.Millisecond)
		if !platform.Publish(ctx, w, platform.Message(req.CardID, d)) {
			return
		}
		if err := r.CommitMessages(ctx, m); err != nil {
			log.Printf("Kafka commit failed: %v", err)
		}
		stats.Add(d.Decision, "SCORER", d.ScorerMS, false, false)
	}
}
func main() {
	ctx, cancel := platform.Context()
	defer cancel()
	if len(platform.Brokers()) == 0 {
		log.Print("KAFKA_BOOTSTRAP is required")
		return
	}
	var stats metrics.Stats
	done := make(chan struct{})
	go func() { defer close(done); run(ctx, &stats) }()
	go func() {
		prev := stats.Snapshot()
		for platform.Sleep(ctx, 5*time.Second) {
			cur := stats.Snapshot()
			log.Printf("5s: scored %d, declined %d, p99 %.1f ms", cur.Total-prev.Total, cur.Declined-prev.Declined, cur.P99)
			prev = cur
		}
	}()
	mux := http.NewServeMux()
	platform.Health(mux)
	platform.Serve(ctx, platform.Env("LISTEN", ":9091"), mux)
	cancel()
	<-done
}
