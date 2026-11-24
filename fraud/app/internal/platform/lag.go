package platform

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/segmentio/kafka-go"
)

const kafkaLagTimeout = 5 * time.Second
const kafkaLagMaxAge = 30 * time.Second

var lagClient = sync.OnceValue(func() *kafka.Client {
	return &kafka.Client{Addr: kafka.TCP(Brokers()...), Timeout: kafkaLagTimeout, Transport: &kafka.Transport{}}
})

type lagKey struct{ group, topic string }
type lagValue struct {
	lag, end int64
	at       time.Time
}
type lagCollector struct {
	mu    sync.Mutex
	last  map[lagKey]lagValue
	fetch func(context.Context, string, string) (int64, int64, error)
	now   func() time.Time
}

var kafkaLags = lagCollector{fetch: fetchKafkaLag, now: time.Now}

func KafkaLag(ctx context.Context, group, topic string) (int64, int64, error) {
	return kafkaLags.collect(ctx, group, topic)
}

func (c *lagCollector) collect(ctx context.Context, group, topic string) (lag, end int64, err error) {
	key := lagKey{group, topic}
	for attempt := 0; attempt < 2; attempt++ {
		callCtx, cancel := context.WithTimeout(ctx, kafkaLagTimeout)
		lag, end, err = c.fetch(callCtx, group, topic)
		cancel()
		if err == nil {
			c.mu.Lock()
			if c.last == nil {
				c.last = make(map[lagKey]lagValue)
			}
			c.last[key] = lagValue{lag: lag, end: end, at: c.now()}
			c.mu.Unlock()
			return lag, end, nil
		}
		if ctx.Err() != nil {
			break
		}
	}
	c.mu.Lock()
	last, ok := c.last[key]
	fresh := ok && c.now().Sub(last.at) <= kafkaLagMaxAge
	c.mu.Unlock()
	if fresh {
		return last.lag, last.end, nil
	}
	return 0, 0, err
}

func fetchKafkaLag(ctx context.Context, group, topic string) (lag, end int64, err error) {
	if len(Brokers()) == 0 {
		return 0, 0, fmt.Errorf("Kafka is not configured")
	}
	c := lagClient()
	meta, err := c.Metadata(ctx, &kafka.MetadataRequest{Topics: []string{topic}})
	if err != nil {
		return 0, 0, err
	}
	parts := []int{}
	requests := []kafka.OffsetRequest{}
	for _, t := range meta.Topics {
		if t.Error != nil {
			return 0, 0, t.Error
		}
		for _, p := range t.Partitions {
			if p.Error != nil {
				return 0, 0, p.Error
			}
			parts = append(parts, p.ID)
			requests = append(requests, kafka.LastOffsetOf(p.ID), kafka.FirstOffsetOf(p.ID))
		}
	}
	if len(parts) == 0 {
		return 0, 0, fmt.Errorf("topic %s has no partitions", topic)
	}
	offsets, err := c.ListOffsets(ctx, &kafka.ListOffsetsRequest{Topics: map[string][]kafka.OffsetRequest{topic: requests}})
	if err != nil {
		return 0, 0, err
	}
	committed, err := c.OffsetFetch(ctx, &kafka.OffsetFetchRequest{GroupID: group, Topics: map[string][]int{topic: parts}})
	if err != nil {
		return 0, 0, err
	}
	if committed.Error != nil {
		return 0, 0, committed.Error
	}
	byPartition := map[int]int64{}
	for _, p := range committed.Topics[topic] {
		if p.Error != nil {
			return 0, 0, p.Error
		}
		byPartition[p.Partition] = p.CommittedOffset
	}
	for _, p := range offsets.Topics[topic] {
		if p.Error != nil {
			return 0, 0, p.Error
		}
		end += p.LastOffset
		offset, ok := byPartition[p.Partition]
		if !ok || offset < 0 {
			offset = p.FirstOffset
		}
		lag += max(0, p.LastOffset-offset)
	}
	return lag, end, nil
}
