package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/model"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/platform"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
)

const systemPrompt = "You are an assistant for a bank's fraud team. In at most two short plain-English sentences, explain to a customer-support agent why this card payment was blocked. Use only the facts given. Do not invent facts. Do not mention scores."

func explainOne(ctx context.Context, pool *pgxpool.Pool, url string, client *http.Client) (bool, error) {
	ctx, cancel := context.WithTimeout(ctx, 35*time.Second)
	defer cancel()
	tx, err := pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(context.Background())
	var id, last4, merchant, city, country string
	var amount int64
	var raw []byte
	err = tx.QueryRow(ctx, `SELECT txn_id::text,last4,amount_cents,merchant_name,city,country,reasons FROM alerts WHERE explanation IS NULL ORDER BY ts FOR UPDATE SKIP LOCKED LIMIT 1`).Scan(&id, &last4, &amount, &merchant, &city, &country, &raw)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	var reasons []model.Reason
	if err = json.Unmarshal(raw, &reasons); err != nil {
		return false, err
	}
	facts := []string{}
	for _, r := range reasons {
		facts = append(facts, r.Fact)
	}
	user := fmt.Sprintf("Card …%s; amount $%.2f; merchant %s; city %s; country %s. Facts: %s", last4, float64(amount)/100, merchant, city, country, strings.Join(facts, "; "))
	b, _ := json.Marshal(map[string]any{"model": "local", "temperature": .2, "max_tokens": 90, "messages": []map[string]string{{"role": "system", "content": systemPrompt}, {"role": "user", "content": user}}})
	req, err := http.NewRequestWithContext(ctx, "POST", strings.TrimRight(url, "/")+"/v1/chat/completions", bytes.NewReader(b))
	if err != nil {
		return false, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return false, fmt.Errorf("explainer returned %s", resp.Status)
	}
	var answer struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err = json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&answer); err != nil {
		return false, err
	}
	if len(answer.Choices) == 0 || strings.TrimSpace(answer.Choices[0].Message.Content) == "" {
		return false, errors.New("empty explanation")
	}
	explanation := strings.Join(strings.Fields(answer.Choices[0].Message.Content), " ")
	if _, err = tx.Exec(ctx, `UPDATE alerts SET explanation=$2,explained_at=now() WHERE txn_id=$1`, id, explanation); err != nil {
		return false, err
	}
	if err = tx.Commit(ctx); err != nil {
		return false, err
	}
	log.Printf("explanation for card …%s: %s", last4, explanation)
	return true, nil
}
func explain(ctx context.Context, pool *pgxpool.Pool, url string) {
	client := &http.Client{Timeout: 30 * time.Second}
	for ctx.Err() == nil {
		found, err := explainOne(ctx, pool, url, client)
		if err != nil && ctx.Err() == nil {
			log.Printf("explanation unavailable, retrying later: %v", err)
		}
		if err != nil || !found {
			if !platform.Sleep(ctx, 2*time.Second) {
				return
			}
		}
	}
}
