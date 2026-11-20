package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestPanelsFailIndependently(t *testing.T) {
	t.Setenv("KAFKA_BOOTSTRAP", "")
	terminals := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/stats" {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"sent":123,"errors":2,"timeouts":1}`))
	}))
	defer terminals.Close()
	d := dashboard{client: terminals.Client(), terminals: terminals.URL}
	w := httptest.NewRecorder()
	d.stats(w, httptest.NewRequest("GET", "/api/stats", nil))
	var got map[string]struct {
		Data  json.RawMessage `json:"data"`
		Error string          `json:"error"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got["database"].Error != "database unavailable" || got["alerts"].Error != "database unavailable" || got["scorer"].Error != "Kafka unavailable" {
		t.Fatal(w.Body.String())
	}
	var stats struct {
		Sent int `json:"sent"`
	}
	if err := json.Unmarshal(got["terminals"].Data, &stats); err != nil || stats.Sent != 123 {
		t.Fatal("terminal panel failed with other dependencies", w.Body.String())
	}
}
