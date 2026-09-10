package engine

import (
	"math"
	"testing"
)

// GAME-22: bots must react decisively to undercutting, converging toward a
// cheaper competitor within 1-2 reviews instead of drifting ~2% per cycle.
func TestBotRespondsToUndercut(t *testing.T) {
	const base = 150.0
	const priceMult = 1.0
	const threshold = 0.08
	botPrice := 200.0
	competitor := 160.0 // undercuts by 20%

	next := botRespondPrice(botPrice, base, competitor, 1, priceMult, threshold, "Balanced", "stable")

	// Must move meaningfully toward the competitor, not ~2%.
	if next >= botPrice {
		t.Fatalf("bot should lower its price when undercut: got %.2f", next)
	}
	if next < competitor*0.90 {
		t.Fatalf("bot should not crash far below the competitor: got %.2f", next)
	}
	// A second review should get the bot close to the competitor.
	next2 := botRespondPrice(next, base, competitor, 1, priceMult, threshold, "Balanced", "stable")
	if math.Abs(next2-competitor) > math.Abs(next-competitor) {
		t.Fatalf("second review should converge toward competitor: first %.2f second %.2f", next, next2)
	}
	if math.Abs(next2-competitor) > 8.0 {
		t.Fatalf("expected convergence within 2 reviews, still %.2f away", math.Abs(next2-competitor))
	}
}

// A bot priced well above the market should not drop below the marginal base.
func TestBotPriceNeverBelowBaseFloor(t *testing.T) {
	const base = 150.0
	next := botRespondPrice(400.0, base, 10.0, 1, 1.0, 0.08, "Balanced", "stable")
	if next < base*0.9 {
		t.Fatalf("bot price %.2f fell below the base floor %.2f", next, base*0.9)
	}
}

// With no competitor, the bot still moves toward its archetype target.
func TestBotRespondsWithoutCompetitor(t *testing.T) {
	next := botRespondPrice(200.0, 150.0, 0, 0, 1.0, 0.08, "Aggressive", "stable")
	if next <= 0 {
		t.Fatalf("expected a positive target price")
	}
}
