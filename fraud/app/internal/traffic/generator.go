package traffic

import (
	"fmt"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/model"
	"math"
	"math/rand"
	"time"
)

type City struct {
	Name, Country string
	Lat, Lon      float64
}

var Cities = []City{
	{"New York", "US", 40.713, -74.006}, {"Los Angeles", "US", 34.052, -118.244}, {"Chicago", "US", 41.878, -87.630}, {"Houston", "US", 29.760, -95.370}, {"Phoenix", "US", 33.448, -112.074},
	{"Philadelphia", "US", 39.953, -75.165}, {"San Antonio", "US", 29.424, -98.494}, {"San Diego", "US", 32.716, -117.161}, {"Dallas", "US", 32.777, -96.797}, {"San Jose", "US", 37.338, -121.886},
	{"Austin", "US", 30.267, -97.743}, {"Jacksonville", "US", 30.332, -81.656}, {"Fort Worth", "US", 32.755, -97.331}, {"Columbus", "US", 39.961, -82.999}, {"Indianapolis", "US", 39.768, -86.158},
	{"Charlotte", "US", 35.227, -80.843}, {"Seattle", "US", 47.606, -122.332}, {"Denver", "US", 39.739, -104.990}, {"Boston", "US", 42.360, -71.059}, {"Nashville", "US", 36.163, -86.782},
	{"Portland", "US", 45.515, -122.678}, {"Las Vegas", "US", 36.170, -115.140}, {"Detroit", "US", 42.331, -83.046}, {"Memphis", "US", 35.150, -90.049}, {"Baltimore", "US", 39.290, -76.612},
}

type Merchant struct{ Name, MCC string }

var Merchants = []Merchant{
	{"Maple Market", "5411"}, {"Cedar Grocers", "5411"}, {"Willow Foods", "5411"}, {"Harvest Basket", "5411"}, {"Oak Pantry", "5411"}, {"Prairie Produce", "5411"}, {"Elm Corner Store", "5411"}, {"Sunrise Foods", "5411"},
	{"Bluebird Fuel", "5541"}, {"Trailside Gas", "5541"}, {"Canyon Fuel", "5541"}, {"Pine Service Stop", "5541"}, {"Summit Gas", "5541"},
	{"Juniper Kitchen", "5812"}, {"Copper Spoon", "5812"}, {"Riverbend Cafe", "5812"}, {"Lemon Table", "5812"}, {"Stone Oven", "5812"}, {"Meadow Diner", "5812"}, {"Birch Noodles", "5812"},
	{"Orchard Electronics", "5732"}, {"Beacon Devices", "5732"}, {"Circuit Grove", "5732"}, {"Northstar Gadgets", "5732"},
	{"Cloudline Air", "4511"}, {"Horizon Wings", "4511"}, {"Atlas Regional", "4511"},
	{"Fern Books", "5942"}, {"Redwood Pages", "5942"}, {"Pebble Outfitters", "5651"}, {"Silver Thread", "5651"}, {"Clover Apparel", "5651"},
	{"Brook Pharmacy", "5912"}, {"Valley Wellness", "5912"}, {"Acorn Hardware", "5251"}, {"Bridge Tools", "5251"}, {"Garden Gate", "5261"}, {"Starlight Cinema", "7832"}, {"Lakeview Lodging", "7011"}, {"Marigold Flowers", "5992"},
}
var bins = []string{"411111", "424242", "453201", "455673", "510510", "520082", "545454", "555555"}

type Card struct {
	ID, BIN, Last4 string
	Home           City
	last           time.Time
	current        City
}
type Generator struct {
	rng   *rand.Rand
	Cards []Card
	next  int
}

func New(seed int64, n int) *Generator {
	g := &Generator{rng: rand.New(rand.NewSource(seed))}
	for i := 0; i < max(n, 5); i++ {
		home := Cities[g.rng.Intn(len(Cities))]
		g.Cards = append(g.Cards, Card{ID: fmt.Sprintf("c-%010x", g.rng.Uint64()&0xffffffffff), BIN: bins[g.rng.Intn(len(bins))], Last4: fmt.Sprintf("%04d", g.rng.Intn(10000)), Home: home, current: home})
	}
	return g
}
func (g *Generator) Request(card Card, city City, merchant int, amount int64, now time.Time) model.AuthRequest {
	m := Merchants[merchant%len(Merchants)]
	return model.AuthRequest{TxnID: model.UUID(), CardID: card.ID, BIN: card.BIN, Last4: card.Last4, AmountCents: amount, Currency: "USD", MerchantID: fmt.Sprintf("m-%02d", merchant%len(Merchants)), MerchantName: m.Name, MCC: m.MCC, Country: city.Country, City: city.Name, Lat: city.Lat, Lon: city.Lon, TerminalID: fmt.Sprintf("t-%s", card.ID), TS: now}
}
func (g *Generator) Normal(now time.Time) model.AuthRequest {
	c := &g.Cards[g.next%len(g.Cards)]
	g.next++
	city := c.Home
	p := g.rng.Float64()
	if p >= .95 && p < .99 && (c.last.IsZero() || now.Sub(c.last) > 2*time.Hour) {
		city = Cities[g.rng.Intn(len(Cities))]
	} else if !c.last.IsZero() && now.Sub(c.last) <= 2*time.Hour {
		city = c.current
	}
	if p >= .99 {
		city = City{"online", "US", c.Home.Lat, c.Home.Lon}
	} else {
		c.current = city
	}
	c.last = now
	amount := int64(math.Round(math.Min(200000, 3500*math.Exp(g.rng.NormFloat64()*.65))))
	return g.Request(*c, city, g.rng.Intn(len(Merchants)), max(1, amount), now)
}

type Event struct {
	After   time.Duration
	Request model.AuthRequest
	Log     string
}

func (g *Generator) Attacks(scenario string, start time.Time) []Event {
	var events []Event
	add := func(after time.Duration, req model.AuthRequest, message string) {
		req.TS = start.Add(after)
		events = append(events, Event{after, req, message})
	}
	if scenario == "all" || scenario == "card-testing" {
		for i := 0; i < 3; i++ {
			c := g.Cards[i]
			online := City{"online", "US", c.Home.Lat, c.Home.Lon}
			for j := 0; j < 36; j++ {
				after := time.Duration(j)*1500*time.Millisecond + time.Duration(i)*100*time.Millisecond
				message := ""
				if j == 0 {
					message = fmt.Sprintf("attack: card testing on card …%s: 36 probes of $0.50–$3.00", c.Last4)
				}
				add(after, g.Request(c, online, j, int64(50+g.rng.Intn(251)), start), message)
			}
			add(58*time.Second, g.Request(c, online, 20, 180000, start), "")
		}
	}
	if scenario == "all" || scenario == "impossible-travel" {
		dest := []City{{"Lagos", "NG", 6.524, 3.379}, {"Bucharest", "RO", 44.426, 26.103}, {"Manila", "PH", 14.600, 120.984}, {"São Paulo", "BR", -23.550, -46.633}}
		for i := 0; i < 5; i++ {
			c := g.Cards[i]
			add(time.Duration(i)*time.Second, g.Request(c, c.Home, 0, 3500, start), fmt.Sprintf("attack: impossible travel on card …%s from %s", c.Last4, c.Home.Name))
			add(time.Duration(65+i)*time.Second, g.Request(c, dest[i%len(dest)], 21, 90000, start), "")
		}
	}
	if scenario == "all" || scenario == "bin-attack" {
		for i := 0; i < 60; i++ {
			c := Card{ID: fmt.Sprintf("c-%010x", uint64(0xba00000000+i)), BIN: "411111", Last4: fmt.Sprintf("%04d", i), Home: Cities[0]}
			message := ""
			if i == 0 {
				message = "attack: BIN attack on 411111: 60 cards with sequential last4, $1 each"
			}
			add(time.Duration(i)*400*time.Millisecond, g.Request(c, City{"online", "US", c.Home.Lat, c.Home.Lon}, i, 100, start), message)
		}
	}
	return events
}
