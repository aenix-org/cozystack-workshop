package scoring

import (
	"fmt"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/model"
	"math"
	"time"
)

// Weights are deliberately visible for workshop tuning.
type Weights struct{ Bias, CardTesting, BINAttack, Velocity, Travel, NewCountry, HighAmount, MerchantSpread float64 }

var ModelWeights = Weights{Bias: -7, CardTesting: 10, BINAttack: 10, Velocity: 4, Travel: 12, NewCountry: 2, HighAmount: 2, MerchantSpread: 2}

type Location struct {
	Lat     float64   `json:"lat"`
	Lon     float64   `json:"lon"`
	City    string    `json:"city"`
	Country string    `json:"country"`
	TS      time.Time `json:"ts"`
}
type Features struct {
	Count60, Count10, Small10, Merchants10, BINCards60 int
	Last                                               Location
	HomeCountry                                        string
	DistanceKM, SpeedKMH, Minutes                      float64
}

func Distance(lat1, lon1, lat2, lon2 float64) float64 {
	r := math.Pi / 180
	dlat := (lat2 - lat1) * r
	dlon := (lon2 - lon1) * r
	a := math.Sin(dlat/2)*math.Sin(dlat/2) + math.Cos(lat1*r)*math.Cos(lat2*r)*math.Sin(dlon/2)*math.Sin(dlon/2)
	return 6371 * 2 * math.Asin(math.Sqrt(min(1, max(0, a))))
}
func (f *Features) Travel(req model.AuthRequest) {
	if f.Last.TS.IsZero() || req.City == "online" || f.Last.City == "online" {
		return
	}
	f.DistanceKM = Distance(f.Last.Lat, f.Last.Lon, req.Lat, req.Lon)
	f.Minutes = req.TS.Sub(f.Last.TS).Minutes()
	if f.Minutes >= 0 {
		f.SpeedKMH = f.DistanceKM / max(f.Minutes/60, 1.0/3600)
	}
}
func Score(req model.AuthRequest, f Features, threshold float64) model.Decision {
	w := ModelWeights
	z := w.Bias
	reasons := []model.Reason{}
	add := func(code, fact string, weight float64) {
		z += weight
		reasons = append(reasons, model.Reason{Code: code, Fact: fact})
	}
	travel := f.SpeedKMH > 900 && f.DistanceKM > 500
	if travel {
		add("IMPOSSIBLE_TRAVEL", fmt.Sprintf("seen in %s, %s %.1f min ago, now in %s, %s (%.0f km, %.0f km/h)", f.Last.City, f.Last.Country, f.Minutes, req.City, req.Country, f.DistanceKM, f.SpeedKMH), w.Travel)
	}
	if f.Small10 >= 6 {
		add("CARD_TESTING", fmt.Sprintf("%d payments below $5 in 10 minutes", f.Small10), w.CardTesting)
	}
	if f.Count60 >= 12 {
		add("VELOCITY", fmt.Sprintf("%d payments in 60 seconds (%d in 10 minutes)", f.Count60, f.Count10), w.Velocity)
	}
	if f.BINCards60 >= 8 {
		add("BIN_ATTACK", fmt.Sprintf("%d distinct cards on BIN %s paid $2 or less in 60 seconds", f.BINCards60, req.BIN), w.BINAttack)
	}
	if f.HomeCountry != "" && req.Country != f.HomeCountry {
		add("NEW_COUNTRY", fmt.Sprintf("payment in %s; first seen country was %s", req.Country, f.HomeCountry), w.NewCountry)
	}
	if req.AmountCents >= 150000 {
		add("HIGH_AMOUNT", fmt.Sprintf("payment amount $%.2f", float64(req.AmountCents)/100), w.HighAmount)
	}
	if f.Merchants10 >= 6 {
		add("MERCHANT_SPREAD", fmt.Sprintf("%d distinct merchants in 10 minutes", f.Merchants10), w.MerchantSpread)
	}
	score := 1 / (1 + math.Exp(-z))
	decision := "APPROVE"
	if score >= threshold || travel {
		decision = "DECLINE"
	}
	return model.Decision{TxnID: req.TxnID, CardID: req.CardID, Decision: decision, Score: score, Reasons: reasons, TS: time.Now().UTC()}
}
