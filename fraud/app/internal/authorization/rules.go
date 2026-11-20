package authorization

import (
	"fmt"
	"github.com/aenix-org/cozystack-workshop/fraud/app/internal/model"
)

func Static(amount, limit int64) (string, []model.Reason) {
	if amount > limit {
		return "DECLINE", []model.Reason{{Code: "HIGH_AMOUNT", Fact: fmt.Sprintf("amount $%.2f exceeds static limit $%.2f", float64(amount)/100, float64(limit)/100)}}
	}
	return "APPROVE", []model.Reason{}
}
