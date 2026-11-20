package authorization

import "testing"

func TestStatic(t *testing.T) {
	for _, tc := range []struct {
		amount int64
		want   string
	}{{0, "APPROVE"}, {500000, "APPROVE"}, {500001, "DECLINE"}} {
		got, reasons := Static(tc.amount, 500000)
		if got != tc.want {
			t.Fatalf("amount %d: %s", tc.amount, got)
		}
		if got == "DECLINE" && (len(reasons) != 1 || reasons[0].Code != "HIGH_AMOUNT") {
			t.Fatal(reasons)
		}
	}
}
