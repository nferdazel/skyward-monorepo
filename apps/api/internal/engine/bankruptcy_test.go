package engine

import "testing"

// GAME-13: the day-based bankruptcy path must fire only once the player has
// accumulated enough consecutive negative days, and must be disabled when the
// threshold is non-positive.
func TestShouldBankruptOnNegativeDays(t *testing.T) {
	cases := []struct {
		name      string
		negDays   int
		threshold int
		want      bool
	}{
		{"first negative day", 1, 30, false},
		{"one short of threshold", 29, 30, false},
		{"exactly at threshold", 30, 30, true},
		{"past threshold", 45, 30, true},
		{"threshold disabled (zero)", 100, 0, false},
		{"threshold disabled (negative)", 100, -1, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := shouldBankruptOnNegativeDays(tc.negDays, tc.threshold); got != tc.want {
				t.Fatalf("shouldBankruptOnNegativeDays(%d, %d) = %v, want %v",
					tc.negDays, tc.threshold, got, tc.want)
			}
		})
	}
}
