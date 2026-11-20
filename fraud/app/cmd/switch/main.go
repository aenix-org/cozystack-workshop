package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/authorization"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/metrics"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/model"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/platform"
	"github.com/segmentio/kafka-go"
)

type requestWriter interface {
	WriteMessages(context.Context, ...kafka.Message) error
}

type switchService struct {
	host    string
	limit   int64
	timeout time.Duration
	writer  requestWriter
	journal chan model.JournalEntry
	mu      sync.Mutex
	waiters map[string]chan model.Decision
	stats   metrics.Stats
	dropped atomic.Uint64
}

func (s *switchService) authorize(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	var req model.AuthRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req); err != nil {
		http.Error(w, "invalid request", 400)
		return
	}
	if req.CardID == "" || req.AmountCents < 0 {
		http.Error(w, "card_id and nonnegative amount required", 400)
		return
	}
	if req.TxnID == "" {
		req.TxnID = model.UUID()
	}
	if req.TS.IsZero() {
		req.TS = time.Now().UTC()
	}
	decision, reasons := authorization.Static(req.AmountCents, s.limit)
	source := "LEGACY"
	var score *float64
	if s.writer != nil {
		source = "STAND_IN"
		ch := make(chan model.Decision, 1)
		s.mu.Lock()
		if _, exists := s.waiters[req.TxnID]; exists {
			s.mu.Unlock()
			http.Error(w, "transaction already pending", 409)
			return
		}
		s.waiters[req.TxnID] = ch
		s.mu.Unlock()
		defer func() { s.mu.Lock(); delete(s.waiters, req.TxnID); s.mu.Unlock() }()
		ctx, cancel := context.WithTimeout(r.Context(), s.timeout)
		defer cancel()
		if err := s.writer.WriteMessages(ctx, platform.Message(req.CardID, req)); err == nil {
			select {
			case d := <-ch:
				decision = d.Decision
				reasons = d.Reasons
				score = &d.Score
				source = "SCORER"
			case <-ctx.Done():
			}
		}
	}
	ms := float64(time.Since(start)) / float64(time.Millisecond)
	entry := model.JournalEntry{Request: req, Decision: decision, Source: source, Score: score, Reasons: reasons, LatencyMS: ms, SwitchHost: s.host, TS: time.Now().UTC()}
	if s.journal != nil {
		select {
		case s.journal <- entry:
		default:
			s.dropped.Add(1)
		}
	}
	s.stats.Add(decision, source, ms, false, false)
	platform.JSON(w, struct {
		TxnID     string         `json:"txn_id"`
		Decision  string         `json:"decision"`
		Source    string         `json:"source"`
		LatencyMS float64        `json:"latency_ms"`
		Reasons   []model.Reason `json:"reasons"`
	}{req.TxnID, decision, source, ms, reasons})
}
func (s *switchService) readDecisions(ctx context.Context) {
	reading := map[int]bool{}
	for {
		for _, p := range decisionPartitions(ctx) {
			if reading[p] {
				continue
			}
			reading[p] = true
			r := kafka.NewReader(kafka.ReaderConfig{Brokers: platform.Brokers(), Topic: "auth.decisions", Partition: p, MinBytes: 1, MaxBytes: 10e6, MaxWait: 10 * time.Millisecond})
			if err := r.SetOffset(kafka.LastOffset); err != nil {
				log.Printf("decision reader for partition %d: %v", p, err)
			}
			go func() {
				defer r.Close()
				s.consume(ctx, r)
			}()
		}
		if !platform.Sleep(ctx, 10*time.Second) {
			return
		}
	}
}
func decisionPartitions(ctx context.Context) []int {
	for {
		for _, b := range platform.Brokers() {
			conn, err := kafka.DialContext(ctx, "tcp", b)
			if err != nil {
				continue
			}
			parts, err := conn.ReadPartitions("auth.decisions")
			conn.Close()
			if err == nil && len(parts) > 0 {
				ids := make([]int, 0, len(parts))
				for _, p := range parts {
					ids = append(ids, p.ID)
				}
				return ids
			}
		}
		log.Print("waiting for Kafka topic auth.decisions")
		if !platform.Sleep(ctx, 2*time.Second) {
			return nil
		}
	}
}
func (s *switchService) consume(ctx context.Context, r *kafka.Reader) {
	for {
		m, err := r.ReadMessage(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			log.Printf("decision reader unavailable: %v", err)
			if !platform.Sleep(ctx, 2*time.Second) {
				return
			}
			continue
		}
		var d model.Decision
		if json.Unmarshal(m.Value, &d) != nil || (d.Decision != "APPROVE" && d.Decision != "DECLINE") {
			continue
		}
		s.mu.Lock()
		if ch := s.waiters[d.TxnID]; ch != nil {
			select {
			case ch <- d:
			default:
			}
		}
		s.mu.Unlock()
	}
}
func (s *switchService) journalLoop(ctx context.Context, w *kafka.Writer, done chan struct{}) {
	defer close(done)
	for {
		select {
		case e, ok := <-s.journal:
			if !ok {
				return
			}
			batch := []kafka.Message{platform.Message(e.Request.CardID, e)}
			closed := false
		collect:
			for len(batch) < 500 {
				select {
				case next, ok := <-s.journal:
					if !ok {
						closed = true
						break collect
					}
					batch = append(batch, platform.Message(next.Request.CardID, next))
				default:
					break collect
				}
			}
			if !platform.Publish(ctx, w, batch...) || closed {
				return
			}
		case <-ctx.Done():
			return
		}
	}
}

func (s *switchService) summary(ctx context.Context) {
	prev := s.stats.Snapshot()
	for platform.Sleep(ctx, 5*time.Second) {
		cur := s.stats.Snapshot()
		n := cur.Total - prev.Total
		share := 0.0
		if n > 0 {
			share = 100 * float64(cur.BySource["STAND_IN"]-prev.BySource["STAND_IN"]) / float64(n)
		}
		log.Printf("5s: %d authorizations, %d declined, stand-in %.1f%%, p99 %.0f ms", n, cur.Declined-prev.Declined, share, cur.P99)
		if dropped := s.dropped.Swap(0); dropped > 0 {
			log.Printf("journal buffer full, %d entries dropped in 5s", dropped)
		}
		prev = cur
	}
}
func main() {
	ctx, cancel := platform.Context()
	defer cancel()
	host, _ := os.Hostname()
	s := &switchService{host: host, limit: int64(platform.Int("STATIC_LIMIT_CENTS", 500000)), timeout: time.Duration(platform.Int("DECISION_TIMEOUT_MS", 400)) * time.Millisecond, waiters: map[string]chan model.Decision{}}
	var journalCancel context.CancelFunc
	var done chan struct{}
	var jw *kafka.Writer
	if len(platform.Brokers()) > 0 {
		requests := platform.Writer("auth.requests")
		s.writer = requests
		defer requests.Close()
		s.journal = make(chan model.JournalEntry, 99500) // Plus at most 500 entries in the writer.
		jw = platform.Writer("auth.journal")
		defer jw.Close()
		jctx, jcancel := context.WithCancel(context.Background())
		journalCancel = jcancel
		done = make(chan struct{})
		go s.journalLoop(jctx, jw, done)
		// Read every partition of auth.decisions directly, from the newest offset.
		// A consumer group would pause all reads on every rebalance, and each pause
		// sends payments into stand-in.
		// The topic may still be growing to its final partition count when the
		// switch starts, so new partitions are picked up every ten seconds.
		go s.readDecisions(ctx)
		log.Print("switch started in SCORING mode")
	} else {
		log.Print("switch started in LEGACY mode")
	}
	mux := http.NewServeMux()
	platform.Health(mux)
	mux.HandleFunc("POST /authorize", s.authorize)
	mux.HandleFunc("GET /stats", func(w http.ResponseWriter, r *http.Request) { platform.JSON(w, s.stats.Snapshot()) })
	go s.summary(ctx)
	platform.Serve(ctx, platform.Env("LISTEN", ":8080"), mux)
	if done != nil {
		close(s.journal)
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			log.Print("journal shutdown flush timed out")
		}
		journalCancel()
		<-done
	}
}
