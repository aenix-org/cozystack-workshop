package platform

import (
	"context"
	"fmt"
	"github.com/segmentio/kafka-go"
	"time"
)

func KafkaLag(ctx context.Context, group, topic string) (lag, end int64, err error) {
	if len(Brokers()) == 0 {
		return 0, 0, fmt.Errorf("Kafka is not configured")
	}
	c := &kafka.Client{Addr: kafka.TCP(Brokers()...), Timeout: 2 * time.Second}
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
