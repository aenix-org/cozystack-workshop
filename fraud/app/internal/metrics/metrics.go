package metrics

import (
	"math"
	"sort"
	"sync"
)

type Snapshot struct {
	Total    uint64            `json:"total"`
	Approved uint64            `json:"approved"`
	Declined uint64            `json:"declined"`
	BySource map[string]uint64 `json:"by_source"`
	P50      float64           `json:"p50_ms"`
	P99      float64           `json:"p99_ms"`
	Errors   uint64            `json:"errors"`
	Timeouts uint64            `json:"timeouts"`
}
type Stats struct {
	mu                                          sync.Mutex
	total, approved, declined, errors, timeouts uint64
	sources                                     map[string]uint64
	latency                                     [1000]float64
	n                                           int
}

func (s *Stats) Add(decision, source string, ms float64, failed, timeout bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.total++
	if decision == "APPROVE" {
		s.approved++
	}
	if decision == "DECLINE" {
		s.declined++
	}
	if failed {
		s.errors++
	}
	if timeout {
		s.timeouts++
	}
	if s.sources == nil {
		s.sources = map[string]uint64{}
	}
	s.sources[source]++
	s.latency[s.n%1000] = ms
	s.n++
}
func (s *Stats) Snapshot() Snapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := min(s.n, 1000)
	a := append([]float64(nil), s.latency[:n]...)
	sort.Float64s(a)
	p := func(q float64) float64 {
		if n == 0 {
			return 0
		}
		return a[max(0, int(math.Ceil(q*float64(n)))-1)]
	}
	sources := map[string]uint64{}
	for k, v := range s.sources {
		sources[k] = v
	}
	return Snapshot{s.total, s.approved, s.declined, sources, p(.5), p(.99), s.errors, s.timeouts}
}
