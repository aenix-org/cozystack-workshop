package main

import (
	"fmt"
	"net/http"
	"strings"
	"time"
)

func (d *dashboard) metrics(w http.ResponseWriter, r *http.Request) {
	// Serialize refreshes so concurrent scrapes share one collection.
	d.metricsMu.Lock()
	if !time.Now().Before(d.metricsExpires) {
		d.metricsText = renderMetrics(d.collectStats(r.Context(), false))
		d.metricsExpires = time.Now().Add(5 * time.Second)
	}
	body := d.metricsText
	d.metricsMu.Unlock()
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = fmt.Fprint(w, body)
}

func renderMetrics(panels map[string]panel) string {
	var b strings.Builder
	gauge := func(name, help string, value any) {
		fmt.Fprintf(&b, "# HELP fraud_%s %s\n# TYPE fraud_%s gauge\nfraud_%s %v\n", name, help, name, name, value)
	}
	db, dbOK := panels["database"].Data.(databaseStats)
	dbOK = dbOK && panels["database"].Error == ""
	scorer, scorerOK := panels["scorer"].Data.(map[string]int64)
	cases, casesOK := panels["cases"].Data.(map[string]int64)
	kafkaOK := scorerOK && casesOK && panels["scorer"].Error == "" && panels["cases"].Error == ""
	terminals, terminalsOK := panels["terminals"].Data.(map[string]any)
	terminalsOK = terminalsOK && panels["terminals"].Error == ""
	if dbOK {
		gauge("authorizations_per_second", "Authorizations per second over the last 60 seconds.", db.AuthorizationsPerSecond)
		gauge("declines_per_second", "Declines per second over the last 60 seconds.", db.DeclinesPerSecond)
		gauge("stand_in_ratio", "Fraction of stand-in decisions over the last 60 seconds.", max(0, min(1, db.StandInPercent/100)))
		gauge("decision_latency_p50_seconds", "Median decision latency over the last 60 seconds in seconds.", db.P50/1000)
		gauge("decision_latency_p99_seconds", "99th percentile decision latency over the last 60 seconds in seconds.", db.P99/1000)
		gauge("transactions_stored", "Number of stored transactions.", db.Transactions)
		gauge("alerts_total", "Number of alerts.", db.Alerts)
		gauge("alerts_explained", "Number of alerts with explanations.", db.Explained)
	}
	if kafkaOK {
		gauge("scorer_lag_messages", "Kafka scorer consumer group lag in messages.", scorer["lag"])
		gauge("cases_lag_messages", "Kafka cases consumer group lag in messages.", cases["lag"])
		gauge("journal_entries", "Number of journal entries reported by Kafka offsets.", cases["journal_entries"])
		if dbOK {
			gauge("journal_missing", "Journal entries minus stored transactions, floored at zero.", max(int64(0), cases["journal_entries"]-db.Transactions))
		}
	}
	if terminalsOK {
		gauge("terminal_errors_total", "Number of terminal errors.", terminals["errors"])
		gauge("terminal_retried_total", "Number of terminal retries.", terminals["retried"])
		gauge("terminal_sent_total", "Number of transactions sent by terminals.", terminals["sent"])
	}
	b.WriteString("# HELP fraud_panel_up Whether the source was collected successfully (1 or 0).\n# TYPE fraud_panel_up gauge\n")
	for _, source := range []struct {
		name string
		up   bool
	}{{"database", dbOK}, {"kafka", kafkaOK}, {"terminals", terminalsOK}} {
		up := 0
		if source.up {
			up = 1
		}
		fmt.Fprintf(&b, "fraud_panel_up{panel=%q} %d\n", source.name, up)
	}
	return b.String()
}
