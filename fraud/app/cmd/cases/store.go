package main

import (
	"context"
	"encoding/json"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/model"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/segmentio/kafka-go"
)

const schema = `
CREATE TABLE IF NOT EXISTS transactions (
 txn_id uuid PRIMARY KEY, ts timestamptz NOT NULL, card_id text NOT NULL, bin text, last4 text,
 amount_cents bigint, merchant_name text, mcc text, city text, country text,
 decision text, source text, score double precision, latency_ms double precision, switch_host text
);
CREATE TABLE IF NOT EXISTS alerts (
 txn_id uuid PRIMARY KEY REFERENCES transactions(txn_id), ts timestamptz NOT NULL, card_id text, last4 text,
 amount_cents bigint, merchant_name text, city text, country text, score double precision,
 reasons jsonb, explanation text NULL, explained_at timestamptz NULL
);
CREATE INDEX IF NOT EXISTS transactions_ts_idx ON transactions(ts);
CREATE INDEX IF NOT EXISTS alerts_ts_idx ON alerts(ts DESC);
CREATE INDEX IF NOT EXISTS alerts_pending_idx ON alerts(ts) WHERE explanation IS NULL;
`

func store(ctx context.Context, pool *pgxpool.Pool, messages []kafka.Message) (int64, int64, error) {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return 0, 0, err
	}
	defer tx.Rollback(context.Background())
	batch := &pgx.Batch{}
	kinds := []bool{}
	for _, m := range messages {
		var e model.JournalEntry
		if err := json.Unmarshal(m.Value, &e); err != nil {
			return 0, 0, err
		}
		r := e.Request
		batch.Queue(`INSERT INTO transactions (txn_id,ts,card_id,bin,last4,amount_cents,merchant_name,mcc,city,country,decision,source,score,latency_ms,switch_host) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15) ON CONFLICT DO NOTHING`, r.TxnID, r.TS, r.CardID, r.BIN, r.Last4, r.AmountCents, r.MerchantName, r.MCC, r.City, r.Country, e.Decision, e.Source, e.Score, e.LatencyMS, e.SwitchHost)
		kinds = append(kinds, false)
		if e.Decision == "DECLINE" {
			reasons, _ := json.Marshal(e.Reasons)
			batch.Queue(`INSERT INTO alerts (txn_id,ts,card_id,last4,amount_cents,merchant_name,city,country,score,reasons) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) ON CONFLICT DO NOTHING`, r.TxnID, r.TS, r.CardID, r.Last4, r.AmountCents, r.MerchantName, r.City, r.Country, e.Score, reasons)
			kinds = append(kinds, true)
		}
	}
	result := tx.SendBatch(ctx, batch)
	var stored, alerts int64
	for _, alert := range kinds {
		tag, e := result.Exec()
		if e != nil {
			_ = result.Close()
			return 0, 0, e
		}
		if alert {
			alerts += tag.RowsAffected()
		} else {
			stored += tag.RowsAffected()
		}
	}
	if err := result.Close(); err != nil {
		return 0, 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, 0, err
	}
	return stored, alerts, nil
}
