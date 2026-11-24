package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestRenderMetrics(t *testing.T) {
	healthy := func() map[string]panel {
		return map[string]panel{
			"database":  {Data: databaseStats{AuthorizationsPerSecond: 12.5, DeclinesPerSecond: 2, StandInPercent: 25, P50: 15, P99: 125, Transactions: 90, Alerts: 8, Explained: 6}},
			"scorer":    {Data: map[string]int64{"lag": 7}},
			"cases":     {Data: map[string]int64{"lag": 3, "journal_entries": 100}},
			"terminals": {Data: map[string]any{"errors": float64(2), "retried": float64(4), "sent": float64(120)}},
		}
	}
	expected := []string{
		"fraud_authorizations_per_second 12.5", "fraud_declines_per_second 2", "fraud_stand_in_ratio 0.25",
		"fraud_decision_latency_p50_seconds 0.015", "fraud_decision_latency_p99_seconds 0.125",
		"fraud_transactions_stored 90", "fraud_alerts_total 8", "fraud_alerts_explained 6",
		"fraud_scorer_lag_messages 7", "fraud_cases_lag_messages 3", "fraud_journal_entries 100", "fraud_journal_missing 10",
		"fraud_terminal_errors_total 2", "fraud_terminal_retried_total 4", "fraud_terminal_sent_total 120",
		`fraud_panel_up{panel="database"} 1`, `fraud_panel_up{panel="kafka"} 1`, `fraud_panel_up{panel="terminals"} 1`,
	}
	t.Run("healthy", func(t *testing.T) {
		text := renderMetrics(healthy())
		var samples []string
		for _, line := range strings.Split(strings.TrimSuffix(text, "\n"), "\n") {
			if !strings.HasPrefix(line, "#") {
				samples = append(samples, line)
			}
		}
		if strings.Join(samples, "\n") != strings.Join(expected, "\n") {
			t.Fatalf("unexpected samples:\n%s", text)
		}
		for _, sample := range expected {
			name := strings.Fields(sample)[0]
			if i := strings.IndexByte(name, '{'); i >= 0 {
				name = name[:i]
			}
			if !strings.Contains(text, "# HELP "+name+" ") || !strings.Contains(text, "# TYPE "+name+" gauge\n") {
				t.Errorf("missing metadata for %s", name)
			}
		}
	})
	for _, source := range []string{"database", "scorer", "cases", "terminals", "all"} {
		t.Run("unavailable_"+source, func(t *testing.T) {
			panels := healthy()
			for key, p := range panels {
				if source == "all" || key == source {
					p.Error = "unavailable"
					panels[key] = p
				}
			}
			text := renderMetrics(panels)
			dbUp := source != "database" && source != "all"
			kafkaUp := source != "scorer" && source != "cases" && source != "all"
			terminalUp := source != "terminals" && source != "all"
			for _, sample := range expected[:15] {
				want := dbUp
				if strings.HasPrefix(sample, "fraud_terminal_") {
					want = terminalUp
				} else if strings.HasPrefix(sample, "fraud_scorer_") || strings.HasPrefix(sample, "fraud_cases_") || strings.HasPrefix(sample, "fraud_journal_entries") {
					want = kafkaUp
				} else if strings.HasPrefix(sample, "fraud_journal_missing") {
					want = dbUp && kafkaUp
				}
				if strings.Contains(text, sample+"\n") != want {
					t.Errorf("sample %q presence should be %v:\n%s", sample, want, text)
				}
			}
			for name, up := range map[string]bool{"database": dbUp, "kafka": kafkaUp, "terminals": terminalUp} {
				value := "0"
				if up {
					value = "1"
				}
				if !strings.Contains(text, `fraud_panel_up{panel="`+name+`"} `+value+"\n") {
					t.Errorf("wrong availability:\n%s", text)
				}
			}
		})
	}
	t.Run("missing_floored_at_zero", func(t *testing.T) {
		panels := healthy()
		panels["cases"].Data.(map[string]int64)["journal_entries"] = 80
		if text := renderMetrics(panels); !strings.Contains(text, "fraud_journal_missing 0\n") {
			t.Fatal(text)
		}
	})
	t.Run("no_data", func(t *testing.T) {
		want := "# HELP fraud_panel_up Whether the source was collected successfully (1 or 0).\n" +
			"# TYPE fraud_panel_up gauge\n" +
			"fraud_panel_up{panel=\"database\"} 0\n" +
			"fraud_panel_up{panel=\"kafka\"} 0\n" +
			"fraud_panel_up{panel=\"terminals\"} 0\n"
		if got := renderMetrics(nil); got != want {
			t.Fatalf("got:\n%swant:\n%s", got, want)
		}
	})
}

func TestMetricsCache(t *testing.T) {
	t.Setenv("KAFKA_BOOTSTRAP", "")
	var calls atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		_, _ = w.Write([]byte(`{"sent":123,"errors":2,"retried":1}`))
	}))
	defer server.Close()
	d := dashboard{client: server.Client(), terminals: server.URL}
	scrape := func() {
		w := httptest.NewRecorder()
		d.metrics(w, httptest.NewRequest("GET", "/metrics", nil))
		if w.Code != http.StatusOK || w.Header().Get("Content-Type") != "text/plain; version=0.0.4; charset=utf-8" || !strings.Contains(w.Body.String(), "fraud_terminal_sent_total 123\n") {
			t.Errorf("unexpected response: %v %s", w.Result().Header, w.Body.String())
		}
	}
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); scrape() }()
	}
	wg.Wait()
	if n := calls.Load(); n != 1 {
		t.Fatalf("collected %d times, want 1", n)
	}
	d.metricsMu.Lock()
	d.metricsExpires = time.Now().Add(-time.Second)
	d.metricsMu.Unlock()
	scrape()
	if n := calls.Load(); n != 2 {
		t.Fatalf("collected %d times after expiration, want 2", n)
	}
}
