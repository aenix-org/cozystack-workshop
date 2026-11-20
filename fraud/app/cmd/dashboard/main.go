package main

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/model"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/platform"
	"github.com/jackc/pgx/v5/pgxpool"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"
)

//go:embed static/index.html
var page embed.FS

type databaseStats struct {
	AuthorizationsPerSecond float64 `json:"authorizations_per_second"`
	DeclinesPerSecond       float64 `json:"declines_per_second"`
	Approved                int64   `json:"approved"`
	Declined                int64   `json:"declined"`
	StandInPercent          float64 `json:"stand_in_percent"`
	P50                     float64 `json:"p50_ms"`
	P99                     float64 `json:"p99_ms"`
	Transactions            int64   `json:"transactions"`
	Alerts                  int64   `json:"alerts"`
	Explained               int64   `json:"explained"`
}
type alert struct {
	TxnID       string         `json:"txn_id"`
	TS          time.Time      `json:"ts"`
	Last4       string         `json:"last4"`
	Amount      int64          `json:"amount_cents"`
	Merchant    string         `json:"merchant_name"`
	City        string         `json:"city"`
	Country     string         `json:"country"`
	Reasons     []model.Reason `json:"reasons"`
	Explanation *string        `json:"explanation"`
}
type panel struct {
	Data  any    `json:"data,omitempty"`
	Error string `json:"error,omitempty"`
}
type dashboard struct {
	pool      *pgxpool.Pool
	client    *http.Client
	terminals string
}

func (d *dashboard) database(ctx context.Context) panel {
	if d.pool == nil {
		return panel{Error: "database unavailable"}
	}
	var s databaseStats
	err := d.pool.QueryRow(ctx, `SELECT count(*)/60.0, count(*) FILTER (WHERE decision='DECLINE')/60.0,
 count(*) FILTER (WHERE decision='APPROVE'),count(*) FILTER (WHERE decision='DECLINE'),
 COALESCE(100.0*count(*) FILTER (WHERE source='STAND_IN')/NULLIF(count(*),0),0),
 COALESCE(percentile_cont(0.5) WITHIN GROUP (ORDER BY latency_ms),0),COALESCE(percentile_cont(0.99) WITHIN GROUP (ORDER BY latency_ms),0)
 FROM transactions WHERE ts>=now()-interval '60 seconds'`).Scan(&s.AuthorizationsPerSecond, &s.DeclinesPerSecond, &s.Approved, &s.Declined, &s.StandInPercent, &s.P50, &s.P99)
	if err == nil {
		err = d.pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM transactions),count(*),count(explanation) FROM alerts`).Scan(&s.Transactions, &s.Alerts, &s.Explained)
	}
	if err != nil {
		return panel{Error: "database unavailable"}
	}
	return panel{Data: s}
}
func (d *dashboard) alerts(ctx context.Context) panel {
	if d.pool == nil {
		return panel{Error: "database unavailable"}
	}
	rows, err := d.pool.Query(ctx, `SELECT txn_id::text,ts,last4,amount_cents,merchant_name,city,country,reasons,explanation FROM alerts ORDER BY ts DESC LIMIT 25`)
	if err != nil {
		return panel{Error: "database unavailable"}
	}
	defer rows.Close()
	list := []alert{}
	for rows.Next() {
		var a alert
		var reasons []byte
		if err = rows.Scan(&a.TxnID, &a.TS, &a.Last4, &a.Amount, &a.Merchant, &a.City, &a.Country, &reasons, &a.Explanation); err != nil {
			return panel{Error: "database unavailable"}
		}
		if err = json.Unmarshal(reasons, &a.Reasons); err != nil {
			return panel{Error: "invalid stored reasons"}
		}
		list = append(list, a)
	}
	if rows.Err() != nil {
		return panel{Error: "database unavailable"}
	}
	return panel{Data: list}
}
func (d *dashboard) terminalStats(ctx context.Context) panel {
	if d.terminals == "" {
		return panel{Error: "terminals not configured"}
	}
	req, err := http.NewRequestWithContext(ctx, "GET", d.terminals+"/stats", nil)
	if err != nil {
		return panel{Error: "terminals unavailable"}
	}
	resp, err := d.client.Do(req)
	if err != nil {
		return panel{Error: "terminals unavailable"}
	}
	defer resp.Body.Close()
	var stats map[string]any
	if resp.StatusCode != 200 || json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&stats) != nil {
		return panel{Error: "terminals unavailable"}
	}
	return panel{Data: stats}
}
func (d *dashboard) stats(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2500*time.Millisecond)
	defer cancel()
	var db, alerts, scorer, cases, terminals panel
	var wg sync.WaitGroup
	tasks := []func(){func() { db = d.database(ctx) }, func() { alerts = d.alerts(ctx) }, func() {
		lag, _, err := platform.KafkaLag(ctx, "scorer", "auth.requests")
		if err != nil {
			scorer = panel{Error: "Kafka unavailable"}
		} else {
			scorer = panel{Data: map[string]int64{"lag": lag}}
		}
	}, func() {
		lag, end, err := platform.KafkaLag(ctx, "cases", "auth.journal")
		if err != nil {
			cases = panel{Error: "Kafka unavailable"}
		} else {
			cases = panel{Data: map[string]int64{"lag": lag, "journal_entries": end}}
		}
	}, func() { terminals = d.terminalStats(ctx) }}
	for _, task := range tasks {
		wg.Add(1)
		go func(f func()) { defer wg.Done(); f() }(task)
	}
	wg.Wait()
	w.Header().Set("Cache-Control", "no-store")
	platform.JSON(w, map[string]panel{"database": db, "alerts": alerts, "scorer": scorer, "cases": cases, "terminals": terminals})
}
func main() {
	ctx, cancel := platform.Context()
	defer cancel()
	d := &dashboard{client: &http.Client{Timeout: 2 * time.Second}, terminals: strings.TrimRight(platform.Env("TERMINALS_URL", ""), "/")}
	if url := platform.Env("PG_URL", ""); url != "" {
		cfg, err := pgxpool.ParseConfig(url)
		if err == nil {
			cfg.ConnConfig.ConnectTimeout = 2 * time.Second
			d.pool, err = pgxpool.NewWithConfig(ctx, cfg)
		}
		if err != nil {
			log.Print("database unavailable: invalid pool configuration")
		}
		if d.pool != nil {
			defer d.pool.Close()
		}
	}
	mux := http.NewServeMux()
	platform.Health(mux)
	mux.HandleFunc("GET /api/stats", d.stats)
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		b, err := page.ReadFile("static/index.html")
		if err != nil {
			http.Error(w, fmt.Sprint(err), 500)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(b)
	})
	platform.Serve(ctx, platform.Env("LISTEN", ":8080"), mux)
}
