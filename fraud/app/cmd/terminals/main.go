package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/metrics"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/model"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/platform"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/traffic"
	"log"
	"net"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type simulator struct {
	stats     metrics.Stats
	rate      atomic.Int64
	lastError atomic.Int64
	sent      atomic.Uint64
	mode, url string
	client    *http.Client
	slots     chan struct{}
	wg        sync.WaitGroup
}

func (s *simulator) send(ctx context.Context, req model.AuthRequest) bool {
	select {
	case s.slots <- struct{}{}:
	case <-ctx.Done():
		return false
	}
	s.sent.Add(1)
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		defer func() { <-s.slots }()
		start := time.Now()
		b, _ := json.Marshal(req)
		r, err := http.NewRequestWithContext(ctx, "POST", s.url+"/authorize", bytes.NewReader(b))
		decision := ""
		if err == nil {
			r.Header.Set("Content-Type", "application/json")
			var resp *http.Response
			resp, err = s.client.Do(r)
			if err == nil {
				defer resp.Body.Close()
				if resp.StatusCode != 200 {
					err = errors.New(resp.Status)
				} else {
					var answer struct {
						Decision string `json:"decision"`
					}
					err = json.NewDecoder(resp.Body).Decode(&answer)
					decision = answer.Decision
					if err == nil && decision != "APPROVE" && decision != "DECLINE" {
						err = errors.New("invalid switch decision")
					}
				}
			}
		}
		timeout := false
		if err != nil {
			var e net.Error
			timeout = errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &e) && e.Timeout())
			now := time.Now().Unix()
			old := s.lastError.Load()
			if now != old && s.lastError.CompareAndSwap(old, now) {
				log.Printf("switch unreachable: %v", err)
			}
		}
		s.stats.Add(decision, "", float64(time.Since(start))/float64(time.Millisecond), err != nil, timeout)
	}()
	return true
}
func (s *simulator) snapshot() any {
	v := s.stats.Snapshot()
	return struct {
		Sent     uint64  `json:"sent"`
		Approved uint64  `json:"approved"`
		Declined uint64  `json:"declined"`
		Errors   uint64  `json:"errors"`
		Timeouts uint64  `json:"timeouts"`
		P50      float64 `json:"p50_ms"`
		P99      float64 `json:"p99_ms"`
		Rate     int64   `json:"rate"`
		Mode     string  `json:"mode"`
	}{s.sent.Load(), v.Approved, v.Declined, v.Errors, v.Timeouts, v.P50, v.P99, s.rate.Load(), s.mode}
}

// The ticker caps both normal and scheduled attack traffic at the current rate.
func (s *simulator) run(ctx context.Context, g *traffic.Generator) {
	ticker := time.NewTicker(time.Second / time.Duration(max(1, s.rate.Load())))
	defer ticker.Stop()
	old := s.rate.Load()
	tick := func() bool {
		for {
			select {
			case <-ctx.Done():
				return false
			case <-ticker.C:
				rate := s.rate.Load()
				if rate != old {
					ticker.Reset(time.Second / time.Duration(max(1, rate)))
					old = rate
				}
				if rate > 0 {
					return true
				}
			}
		}
	}
	if s.mode == "attack" {
		start := time.Now()
		events := g.Attacks(platform.Env("SCENARIO", "all"), start)
		sort.SliceStable(events, func(i, j int) bool { return events[i].After < events[j].After })
		for _, event := range events {
			if delay := time.Until(start.Add(event.After)); delay > 0 && !platform.Sleep(ctx, delay) {
				return
			}
			if !tick() {
				return
			}
			if event.Log != "" {
				log.Print(event.Log)
			}
			event.Request.TS = time.Now().UTC()
			if !s.send(ctx, event.Request) {
				return
			}
		}
		<-ctx.Done()
		return
	}
	for tick() {
		if !s.send(ctx, g.Normal(time.Now().UTC())) {
			return
		}
	}
}

func main() {
	ctx, cancel := platform.Context()
	defer cancel()
	url := strings.TrimRight(platform.Env("SWITCH_URL", ""), "/")
	if url == "" {
		log.Print("SWITCH_URL is required")
		return
	}
	mode := platform.Env("MODE", "normal")
	scenario := platform.Env("SCENARIO", "all")
	if mode != "normal" && mode != "attack" {
		log.Print("MODE must be normal or attack")
		return
	}
	if mode == "attack" && scenario != "all" && scenario != "card-testing" && scenario != "impossible-travel" && scenario != "bin-attack" {
		log.Print("invalid SCENARIO")
		return
	}
	duration := platform.Env("DURATION", "")
	if duration == "" && mode == "attack" {
		duration = "90s"
	}
	if duration != "" {
		d, err := time.ParseDuration(duration)
		if err != nil {
			log.Printf("invalid DURATION: %v", err)
			return
		}
		var stop context.CancelFunc
		ctx, stop = context.WithTimeout(ctx, d)
		defer stop()
	}
	s := &simulator{url: url, mode: mode, client: &http.Client{Timeout: 2 * time.Second}, slots: make(chan struct{}, 64)}
	s.rate.Store(int64(min(1000000, max(0, platform.Int("RATE", 20)))))
	go func() {
		prev := s.stats.Snapshot()
		for platform.Sleep(ctx, 5*time.Second) {
			v := s.stats.Snapshot()
			log.Printf("5s: sent %d, approved %d, declined %d, errors %d, timeouts %d, p99 %.1f ms", v.Total-prev.Total, v.Approved-prev.Approved, v.Declined-prev.Declined, v.Errors-prev.Errors, v.Timeouts-prev.Timeouts, v.P99)
			prev = v
		}
	}()
	if file := platform.Env("RATE_FILE", ""); file != "" {
		go func() {
			for {
				b, err := os.ReadFile(file)
				if err == nil {
					if n, e := strconv.Atoi(strings.TrimSpace(string(b))); e == nil && n >= 0 && n <= 1000000 {
						s.rate.Store(int64(n))
					}
				}
				if !platform.Sleep(ctx, 2*time.Second) {
					return
				}
			}
		}()
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		s.run(ctx, traffic.New(int64(platform.Int("SEED", 42)), platform.Int("CARDS", 3000)))
	}()
	mux := http.NewServeMux()
	platform.Health(mux)
	mux.HandleFunc("GET /stats", func(w http.ResponseWriter, r *http.Request) { platform.JSON(w, s.snapshot()) })
	platform.Serve(ctx, platform.Env("LISTEN", ":9090"), mux)
	cancel()
	<-done
	s.wg.Wait()
}
