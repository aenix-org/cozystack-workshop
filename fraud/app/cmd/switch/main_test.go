package main

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/model"
	"github.com/segmentio/kafka-go"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type fakeWriter func(context.Context, ...kafka.Message) error

func (f fakeWriter) WriteMessages(ctx context.Context, m ...kafka.Message) error { return f(ctx, m...) }
func TestAuthorizationSources(t *testing.T) {
	for _, tc := range []struct {
		name, source, decision string
		amount                 int
		mode                   string
	}{{"legacy approval", "LEGACY", "APPROVE", 100, ""}, {"legacy decline", "LEGACY", "DECLINE", 500001, ""}, {"Kafka failure", "STAND_IN", "APPROVE", 100, "error"}, {"timeout decline", "STAND_IN", "DECLINE", 500001, "timeout"}, {"scorer decision", "SCORER", "DECLINE", 100, "scorer"}} {
		t.Run(tc.name, func(t *testing.T) {
			s := &switchService{host: "test", limit: 500000, timeout: 5 * time.Millisecond, waiters: map[string]chan model.Decision{}, journal: make(chan model.JournalEntry, 1)}
			if tc.mode != "" {
				s.writer = fakeWriter(func(ctx context.Context, m ...kafka.Message) error {
					if tc.mode == "error" {
						return errors.New("offline")
					}
					if tc.mode == "scorer" {
						var req model.AuthRequest
						_ = json.Unmarshal(m[0].Value, &req)
						s.mu.Lock()
						s.waiters[req.TxnID] <- model.Decision{Decision: "DECLINE", Score: .99, Reasons: []model.Reason{{Code: "CARD_TESTING", Fact: "6 probes"}}}
						s.mu.Unlock()
					}
					return nil
				})
			}
			b, _ := json.Marshal(model.AuthRequest{CardID: "c-test", AmountCents: int64(tc.amount)})
			r := httptest.NewRequest("POST", "/authorize", strings.NewReader(string(b)))
			w := httptest.NewRecorder()
			s.authorize(w, r)
			if w.Code != 200 {
				t.Fatal(w.Code, w.Body.String())
			}
			var got struct {
				TxnID    string `json:"txn_id"`
				Decision string
				Source   string
			}
			if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
				t.Fatal(err)
			}
			if got.Source != tc.source || got.Decision != tc.decision || got.TxnID == "" {
				t.Fatalf("response %+v", got)
			}
			e := <-s.journal
			if e.Request.TS.IsZero() || e.Source != tc.source {
				t.Fatalf("journal %+v", e)
			}
			if tc.source == "SCORER" && e.Score == nil {
				t.Fatal("missing score")
			}
			if tc.source != "SCORER" && e.Score != nil {
				t.Fatal("static score must be null")
			}
			if len(s.waiters) != 0 {
				t.Fatal("waiter leaked")
			}
			if s.stats.Snapshot().Total != 1 {
				t.Fatal("missing stats")
			}
		})
	}
}
func TestJournalFullDoesNotBlockAnswer(t *testing.T) {
	s := &switchService{limit: 500000, journal: make(chan model.JournalEntry, 1)}
	s.journal <- model.JournalEntry{}
	done := make(chan struct{})
	go func() {
		defer close(done)
		s.authorize(httptest.NewRecorder(), httptest.NewRequest("POST", "/authorize", strings.NewReader(`{"card_id":"c-test","amount_cents":10}`)))
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("HTTP blocked by journal")
	}
}
