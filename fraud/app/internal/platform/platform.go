package platform

import (
	"bytes"
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/segmentio/kafka-go"
)

func Env(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return fallback
}
func Int(key string, fallback int) int {
	v, e := strconv.Atoi(os.Getenv(key))
	if e != nil {
		return fallback
	}
	return v
}
func Float(key string, fallback float64) float64 {
	v, e := strconv.ParseFloat(os.Getenv(key), 64)
	if e != nil {
		return fallback
	}
	return v
}

// Keep network errors and model output on one physical log line.
type lineWriter struct{}

func (lineWriter) Write(p []byte) (int, error) {
	line := bytes.TrimSuffix(p, []byte("\n"))
	line = bytes.ReplaceAll(line, []byte("\n"), []byte(" "))
	line = bytes.ReplaceAll(line, []byte("\r"), []byte(" "))
	_, err := os.Stdout.Write(append(line, '\n'))
	if err != nil {
		return 0, err
	}
	return len(p), nil
}

func Context() (context.Context, context.CancelFunc) {
	log.SetOutput(lineWriter{})
	log.SetFlags(log.Ldate | log.Ltime)
	return signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
}
func Brokers() []string {
	var out []string
	for _, s := range strings.Split(os.Getenv("KAFKA_BOOTSTRAP"), ",") {
		if s = strings.TrimSpace(s); s != "" {
			out = append(out, s)
		}
	}
	return out
}
func Writer(topic string) *kafka.Writer {
	return &kafka.Writer{Addr: kafka.TCP(Brokers()...), Topic: topic, Balancer: &kafka.Hash{}, BatchTimeout: 2 * time.Millisecond, RequiredAcks: kafka.RequireOne, AllowAutoTopicCreation: false, WriteTimeout: 2 * time.Second, ReadTimeout: 2 * time.Second, MaxAttempts: 1}
}
func Reader(topic, group string) *kafka.Reader {
	return kafka.NewReader(kafka.ReaderConfig{Brokers: Brokers(), Topic: topic, GroupID: group, WatchPartitionChanges: true, PartitionWatchInterval: 5 * time.Second, MinBytes: 1, MaxBytes: 10e6, MaxWait: 10 * time.Millisecond, CommitInterval: time.Second})
}
func Message(key string, v any) kafka.Message {
	b, _ := json.Marshal(v)
	return kafka.Message{Key: []byte(key), Value: b}
}
func JSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
func Health(mux *http.ServeMux) {
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("ok")) })
}
func Serve(ctx context.Context, addr string, mux *http.ServeMux) {
	s := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 5 * time.Second, IdleTimeout: 60 * time.Second}
	shutdownDone := make(chan struct{})
	go func() {
		defer close(shutdownDone)
		<-ctx.Done()
		c, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := s.Shutdown(c); err != nil {
			_ = s.Close()
		}
	}()
	log.Printf("HTTP listening on %s", addr)
	if err := s.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Printf("HTTP server stopped: %v", err)
	}
	if ctx.Err() != nil {
		<-shutdownDone
	}
}
func Sleep(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}
func Publish(ctx context.Context, w *kafka.Writer, m ...kafka.Message) bool {
	for {
		if err := w.WriteMessages(ctx, m...); err == nil {
			return true
		} else if ctx.Err() != nil {
			return false
		} else {
			log.Printf("Kafka unavailable, retrying: %v", err)
		}
		if !Sleep(ctx, 2*time.Second) {
			return false
		}
	}
}
