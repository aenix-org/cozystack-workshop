package platform

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestKafkaLagLastGoodValue(t *testing.T) {
	start := time.Now()
	now := start
	unavailable := errors.New("Kafka unavailable")
	var fetchErr error
	calls := 0
	c := lagCollector{
		now: func() time.Time { return now },
		fetch: func(ctx context.Context, group, topic string) (int64, int64, error) {
			calls++
			deadline, ok := ctx.Deadline()
			if !ok || time.Until(deadline) <= 0 || time.Until(deadline) > 5*time.Second {
				t.Fatal("expected a five-second call deadline")
			}
			if fetchErr != nil {
				return 0, 0, fetchErr
			}
			return 7, 42, nil
		},
	}
	lag, end, err := c.collect(context.Background(), "cases", "auth.journal")
	if err != nil || lag != 7 || end != 42 || calls != 1 {
		t.Fatalf("initial collection = (%d, %d, %v), calls = %d", lag, end, err, calls)
	}
	fetchErr = unavailable
	for _, age := range []time.Duration{time.Second, 29 * time.Second, 30 * time.Second, 30*time.Second + time.Nanosecond} {
		now = start.Add(age)
		calls = 0
		lag, end, err = c.collect(context.Background(), "cases", "auth.journal")
		if calls != 2 {
			t.Fatalf("age %v: got %d attempts, want 2", age, calls)
		}
		if age <= 30*time.Second {
			if err != nil || lag != 7 || end != 42 {
				t.Fatalf("age %v: cached collection = (%d, %d, %v)", age, lag, end, err)
			}
		} else if !errors.Is(err, unavailable) || lag != 0 || end != 0 {
			t.Fatalf("expired collection = (%d, %d, %v)", lag, end, err)
		}
	}
	// A failure must neither renew the timestamp nor populate another key.
	now = start.Add(time.Second)
	for _, key := range []lagKey{{"scorer", "auth.journal"}, {"cases", "auth.requests"}} {
		if _, _, err := c.collect(context.Background(), key.group, key.topic); !errors.Is(err, unavailable) {
			t.Fatalf("uncached key %v: got error %v", key, err)
		}
	}
}

func TestKafkaLagRetrySucceeds(t *testing.T) {
	calls := 0
	c := lagCollector{
		now: time.Now,
		fetch: func(context.Context, string, string) (int64, int64, error) {
			calls++
			if calls == 1 {
				return 0, 0, errors.New("temporary failure")
			}
			return 3, 99, nil
		},
	}
	lag, end, err := c.collect(context.Background(), "cases", "auth.journal")
	if err != nil || lag != 3 || end != 99 || calls != 2 {
		t.Fatalf("retry = (%d, %d, %v), calls = %d", lag, end, err, calls)
	}
}
