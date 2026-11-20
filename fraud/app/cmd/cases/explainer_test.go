package main

import "testing"

func TestUsable(t *testing.T) {
	facts := "Card …4242; amount $1.20. Facts: 36 payments below $5 in 10 minutes"
	cases := map[string]bool{
		"The card made 36 payments below $5 in 10 minutes, which is how stolen cards are tested.": true,
		"The card made 360 payments below $5 in 10 minutes.":                                      false,
		"The card made thirty-six payments in six seconds.":                                       false,
		"The payment looks legitimate and was approved.":                                          false,
		"The card made 36 payments below $5 in 10":                                                false,
	}
	for text, ok := range cases {
		if got := usable(text, facts) != ""; got != ok {
			t.Errorf("usable(%q) = %v, want %v", text, got, ok)
		}
	}
}
