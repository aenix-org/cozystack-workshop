package scoring

import (
	"fmt"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/model"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/traffic"
	"math"
	"sort"
	"testing"
	"time"
)

// This reference window model exercises scoring with the actual terminal profile.
type history struct {
	cards     map[string][]model.AuthRequest
	bins      map[string]map[string]time.Time
	locations map[string]Location
	homes     map[string]string
}

func newHistory() *history {
	return &history{map[string][]model.AuthRequest{}, map[string]map[string]time.Time{}, map[string]Location{}, map[string]string{}}
}
func (h *history) features(r model.AuthRequest) Features {
	list := h.cards[r.CardID]
	list = append(list, r)
	kept := list[:0]
	merchants := map[string]bool{}
	f := Features{Last: h.locations[r.CardID]}
	for _, v := range list {
		age := r.TS.Sub(v.TS)
		if age >= 15*time.Minute {
			continue
		}
		kept = append(kept, v)
		if age <= time.Minute {
			f.Count60++
		}
		if age < 10*time.Minute {
			f.Count10++
			merchants[v.MerchantID] = true
			if v.AmountCents < 500 {
				f.Small10++
			}
		}
	}
	h.cards[r.CardID] = kept
	f.Merchants10 = len(merchants)
	if h.bins[r.BIN] == nil {
		h.bins[r.BIN] = map[string]time.Time{}
	}
	if r.AmountCents <= 200 {
		h.bins[r.BIN][r.CardID] = r.TS
	}
	for card, ts := range h.bins[r.BIN] {
		if r.TS.Sub(ts) >= time.Minute {
			delete(h.bins[r.BIN], card)
		}
	}
	f.BINCards60 = len(h.bins[r.BIN])
	if h.homes[r.CardID] == "" {
		h.homes[r.CardID] = r.Country
	}
	f.HomeCountry = h.homes[r.CardID]
	f.Travel(r)
	if r.City != "online" {
		h.locations[r.CardID] = Location{r.Lat, r.Lon, r.City, r.Country, r.TS}
	}
	return f
}
func TestDistanceAndTravel(t *testing.T) {
	d := Distance(32.777, -96.797, 6.524, 3.379)
	if d < 10500 || d > 11500 {
		t.Fatal(d)
	}
	if Distance(0, 0, 0, 0) != 0 {
		t.Fatal("same location")
	}
	if math.IsNaN(Distance(90, 0, -90, 180)) {
		t.Fatal("antipodal distance")
	}
	now := time.Now()
	r := model.AuthRequest{Country: "NG", City: "Lagos", Lat: 6.524, Lon: 3.379, TS: now}
	f := Features{Last: Location{32.777, -96.797, "Dallas", "US", now.Add(-3 * time.Minute)}}
	f.Travel(r)
	decision := Score(r, f, 1)
	if decision.Decision != "DECLINE" || decision.Reasons[0].Code != "IMPOSSIBLE_TRAVEL" {
		t.Fatal(decision)
	}
}
func TestNormalProfile(t *testing.T) {
	for _, rate := range []int{20, 400} {
		t.Run(fmt.Sprint(rate), func(t *testing.T) {
			g := traffic.New(42, 3000)
			h := newHistory()
			start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
			declines := 0
			const count = 120000
			for i := 0; i < count; i++ {
				r := g.Normal(start.Add(time.Duration(i) * time.Second / time.Duration(rate)))
				if Score(r, h.features(r), .8).Decision == "DECLINE" {
					declines++
				}
			}
			fraction := float64(declines) / count
			t.Logf("rate %d: %d/%d declined (%.4f%%)", rate, declines, count, 100*fraction)
			if fraction >= .005 {
				t.Fatalf("normal declines %.4f%%", fraction*100)
			}
		})
	}
}
func TestAttackScenarios(t *testing.T) {
	for _, scenario := range []string{"card-testing", "bin-attack", "impossible-travel", "all"} {
		t.Run(scenario, func(t *testing.T) {
			g := traffic.New(42, 3000)
			start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
			events := g.Attacks(scenario, start)
			sort.SliceStable(events, func(i, j int) bool { return events[i].After < events[j].After })
			h := newHistory()
			probes := map[string]int{}
			binCards := 0
			caught := map[string]int{}
			for _, e := range events {
				r := e.Request
				f := h.features(r)
				d := Score(r, f, .8)
				for _, reason := range d.Reasons {
					if d.Decision == "DECLINE" {
						caught[reason.Code]++
					}
				}
				if r.AmountCents < 500 && r.Last4 >= "0060" {
					probes[r.CardID]++
					if probes[r.CardID] >= 6 && d.Decision != "DECLINE" {
						t.Fatalf("probe %d approved", probes[r.CardID])
					}
				}
				if r.BIN == "411111" && r.Last4 < "0060" {
					binCards++
					if binCards >= 8 && d.Decision != "DECLINE" {
						t.Fatalf("BIN card %d approved", binCards)
					}
				}
				if r.Country != "US" && d.Decision != "DECLINE" {
					t.Fatalf("travel approved: %+v", f)
				}
			}
			want := map[string]string{"card-testing": "CARD_TESTING", "bin-attack": "BIN_ATTACK", "impossible-travel": "IMPOSSIBLE_TRAVEL"}
			if scenario == "all" {
				for _, code := range want {
					if caught[code] == 0 {
						t.Fatal("uncaught", code)
					}
				}
			} else if caught[want[scenario]] == 0 {
				t.Fatal("no attack caught")
			}
		})
	}
}
func TestFeatureWindows(t *testing.T) {
	h := newHistory()
	start := time.Now()
	r := model.AuthRequest{CardID: "one", BIN: "411111", MerchantID: "shop", Country: "US", City: "Dallas", TS: start, AmountCents: 100}
	for i := 0; i < 6; i++ {
		r.TxnID = fmt.Sprint(i)
		r.TS = start.Add(time.Duration(i) * time.Second)
		h.features(r)
	}
	r.AmountCents = 1000
	r.TS = start.Add(61 * time.Second)
	f := h.features(r)
	if f.Count60 != 6 || f.Small10 != 6 || f.Merchants10 != 1 || f.BINCards60 != 1 {
		t.Fatal(f)
	}
	r.TS = start.Add(16 * time.Minute)
	f = h.features(r)
	if f.Count60 != 1 || f.Count10 != 1 || f.Small10 != 0 || f.BINCards60 != 0 {
		t.Fatal(f)
	}
}
