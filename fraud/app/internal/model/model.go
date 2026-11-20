package model

import (
	"crypto/rand"
	"fmt"
	"time"
)

type AuthRequest struct {
	TxnID        string    `json:"txn_id"`
	CardID       string    `json:"card_id"`
	BIN          string    `json:"bin"`
	Last4        string    `json:"last4"`
	AmountCents  int64     `json:"amount_cents"`
	Currency     string    `json:"currency"`
	MerchantID   string    `json:"merchant_id"`
	MerchantName string    `json:"merchant_name"`
	MCC          string    `json:"mcc"`
	Country      string    `json:"country"`
	City         string    `json:"city"`
	Lat          float64   `json:"lat"`
	Lon          float64   `json:"lon"`
	TerminalID   string    `json:"terminal_id"`
	TS           time.Time `json:"ts"`
}
type Reason struct {
	Code string `json:"code"`
	Fact string `json:"fact"`
}
type Decision struct {
	TxnID    string    `json:"txn_id"`
	CardID   string    `json:"card_id"`
	Decision string    `json:"decision"`
	Score    float64   `json:"score"`
	Reasons  []Reason  `json:"reasons"`
	ScorerMS float64   `json:"scorer_ms"`
	TS       time.Time `json:"ts"`
}
type JournalEntry struct {
	Request    AuthRequest `json:"request"`
	Decision   string      `json:"decision"`
	Source     string      `json:"source"`
	Score      *float64    `json:"score"`
	Reasons    []Reason    `json:"reasons"`
	LatencyMS  float64     `json:"latency_ms"`
	SwitchHost string      `json:"switch_host"`
	TS         time.Time   `json:"ts"`
}

func UUID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return fmt.Sprintf("%08x-0000-4000-8000-%012x", uint32(time.Now().Unix()), time.Now().UnixNano()&0xffffffffffff)
	}
	b[6] = (b[6] & 15) | 64
	b[8] = (b[8] & 63) | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
}
