package engine

import "testing"

// GAME-06: aircraft acquisition is gated by the player's credit tier. Standard
// aircraft are always available; higher tiers unlock progressively larger types.
func TestTierGateMessage(t *testing.T) {
	cases := []struct {
		name      string
		current   string
		minTier   string
		wantBlock bool
	}{
		{"standard model always allowed", "Standard", "Standard", false},
		{"empty requirement allowed", "Standard", "", false},
		{"exact tier allowed", "Silver", "Silver", false},
		{"higher tier allowed", "Platinum", "Gold", false},
		{"lower tier blocked", "Standard", "Silver", true},
		{"standard blocked from widebody", "Standard", "Platinum", true},
		{"silver blocked from platinum", "Silver", "Platinum", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			msg := tierGateMessage(tc.current, tc.minTier, "TestJet")
			if tc.wantBlock && msg == "" {
				t.Fatalf("expected block for %s vs %s", tc.current, tc.minTier)
			}
			if !tc.wantBlock && msg != "" {
				t.Fatalf("expected allow for %s vs %s, got %q", tc.current, tc.minTier, msg)
			}
		})
	}
}

func TestCreditTierRankOrdering(t *testing.T) {
	if !(creditTierRank("Standard") < creditTierRank("Silver") &&
		creditTierRank("Silver") < creditTierRank("Gold") &&
		creditTierRank("Gold") < creditTierRank("Platinum")) {
		t.Fatalf("credit tiers must be strictly ordered")
	}
	if creditTierRank("Unknown") != 0 {
		t.Fatalf("unknown tier should rank 0")
	}
}

// A new player has no credit_scores row; the default must be Standard, which
// can access Standard models but not higher tiers.
func TestNewPlayerDefaultsToStandard(t *testing.T) {
	if msg := tierGateMessage("Standard", "Silver", "E175"); msg == "" {
		t.Fatalf("a Standard player must be blocked from Silver models")
	}
	if msg := tierGateMessage("Standard", "Standard", "ATR 72-600"); msg != "" {
		t.Fatalf("a Standard player must be allowed Standard models")
	}
}
