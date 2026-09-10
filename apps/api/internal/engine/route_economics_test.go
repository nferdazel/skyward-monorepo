package engine

import (
	"math"
	"testing"
)

// AVIATION-18: crew cost scales with aircraft size instead of a flat rate.
func TestCrewCostScalesWithCapacity(t *testing.T) {
	const base = 350.0

	small := crewCostFor(base, 90)  // regional ~0.5x
	mid := crewCostFor(base, 180)   // anchored at 1.0x
	large := crewCostFor(base, 360) // widebody ~2.0x
	huge := crewCostFor(base, 900)  // clamped at 2.5x

	if math.Abs(mid-base) > 0.001 {
		t.Fatalf("180-seat aircraft should use base rate: got %.2f want %.2f", mid, base)
	}
	if !(small < mid && mid < large && large <= huge) {
		t.Fatalf("crew cost must grow with capacity: small=%.2f mid=%.2f large=%.2f huge=%.2f",
			small, mid, large, huge)
	}
	if math.Abs(small-base*0.5) > 0.001 {
		t.Fatalf("90-seat aircraft should clamp to 0.5x: got %.2f", small)
	}
	if math.Abs(huge-base*2.5) > 0.001 {
		t.Fatalf("very large aircraft should clamp to 2.5x: got %.2f", huge)
	}
	// Defensive: zero capacity must not produce zero/negative crew cost.
	if crewCostFor(base, 0) != base {
		t.Fatalf("zero capacity should fall back to base rate")
	}
}

// AVIATION-13: the validation cap must use the real turnaround, so a 0.5h
// aircraft is allowed more cycles than it would be with a hardcoded 1.0h.
func TestCalcMaxWeeklyFlightsUsesTurnaround(t *testing.T) {
	const dist = 1000.0
	const speed = 800

	fast := calcMaxWeeklyFlights(dist, speed, 0.5)
	slow := calcMaxWeeklyFlights(dist, speed, 2.0)
	if fast <= slow {
		t.Fatalf("shorter turnaround must allow more weekly flights: fast=%d slow=%d", fast, slow)
	}
	// 1000/800 + 0.5 = 1.75h -> floor(168/1.75) = 96
	if fast != 96 {
		t.Fatalf("expected 96 weekly flights, got %d", fast)
	}
	// 1000/800 + 2.0 = 3.25h -> floor(168/3.25) = 51
	if slow != 51 {
		t.Fatalf("expected 51 weekly flights, got %d", slow)
	}
	if calcMaxWeeklyFlights(dist, 0, 1.0) != 0 {
		t.Fatalf("zero speed must yield 0")
	}
}
