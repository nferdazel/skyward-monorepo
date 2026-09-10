package engine

import (
	"math"
	"testing"
)

// GAME-02: fixed daily demand pool. These tests lock in the two defining
// behaviours: (1) the reference route reaches a high load factor at 1 flight/day,
// (2) adding frequency past saturation lowers per-flight passengers.

func TestDistanceDemandFactor(t *testing.T) {
	if got := distanceDemandFactor(300); got != 1.0 {
		t.Fatalf("short-haul factor = %v, want 1.0", got)
	}
	if got := distanceDemandFactor(20000); got != 0.35 {
		t.Fatalf("long-haul factor = %v, want 0.35", got)
	}
	// monotonically non-increasing with distance
	prev := math.Inf(1)
	for d := 0.0; d <= 20000; d += 500 {
		got := distanceDemandFactor(d)
		if got > prev {
			t.Fatalf("factor increased at %v: %v > %v", d, got, prev)
		}
		prev = got
	}
}

// Reference route: demand_index 90 both ends, 800km, priced at reference fare.
// With poolScale=290 this should fill a single 180-seat daily flight to ~85-95%.
func TestRouteDailyDemandReferenceRoute(t *testing.T) {
	const (
		poolScale = 290.0
		distance  = 800.0
		baseFare  = 50.0
		perKM     = 0.12
	)
	refFare := baseFare + distance*perKM
	pool := routeDailyDemand(90, 90, distance, refFare, baseFare, perKM, poolScale)

	// At the reference fare the price elasticity term is 1.5-0.8 = 0.7.
	// distanceFactor(800) = 1 + (300/11500)*(0.35-1) ≈ 0.983.
	wantApprox := 290.0 * 0.9 * 0.9 * 0.983 * 0.7
	if math.Abs(pool-wantApprox) > 1.0 {
		t.Fatalf("reference pool = %v, want ~%v", pool, wantApprox)
	}

	seats := 180.0
	load := pool / seats
	if load < 0.85 || load > 0.95 {
		t.Fatalf("single daily flight load = %.3f, want 0.85..0.95", load)
	}
}

// Adding flights to a fixed pool must lower per-flight passengers.
func TestDemandPoolSaturatesWithFrequency(t *testing.T) {
	const (
		poolScale = 290.0
		distance  = 800.0
		baseFare  = 50.0
		perKM     = 0.12
		effCap    = 180.0
		maxLoad   = 0.95
	)
	refFare := baseFare + distance*perKM
	pool := routeDailyDemand(90, 90, distance, refFare, baseFare, perKM, poolScale)

	perFlight := func(flightsPerWeek int) float64 {
		flightsPerDay := float64(flightsPerWeek) / 7.0
		seatsPerDay := flightsPerDay * effCap
		paxPerDay := math.Min(pool, seatsPerDay*maxLoad)
		return math.Floor(paxPerDay / flightsPerDay)
	}

	p1 := perFlight(7)
	p2 := perFlight(14)
	p3 := perFlight(21)

	if !(p1 > p2 && p2 > p3) {
		t.Fatalf("per-flight passengers must fall with frequency: 7/wk=%v 14/wk=%v 21/wk=%v", p1, p2, p3)
	}
	// At high frequency the pool is fully absorbed and load factor collapses.
	flightsPerDay := 3.0
	seatsPerDay := flightsPerDay * effCap
	if got := pool / seatsPerDay; got > 0.5 {
		t.Fatalf("load factor at 3 flights/day = %.3f, expected well below 0.5", got)
	}
}

// Price elasticity: pricing above the reference fare must shrink the pool.
func TestRouteDailyDemandPriceElasticity(t *testing.T) {
	const (
		poolScale = 290.0
		distance  = 800.0
		baseFare  = 50.0
		perKM     = 0.12
	)
	refFare := baseFare + distance*perKM

	cheap := routeDailyDemand(90, 90, distance, refFare*0.7, baseFare, perKM, poolScale)
	ref := routeDailyDemand(90, 90, distance, refFare, baseFare, perKM, poolScale)
	expensive := routeDailyDemand(90, 90, distance, refFare*1.3, baseFare, perKM, poolScale)

	if !(cheap >= ref && ref > expensive) {
		t.Fatalf("expected cheap >= ref > expensive, got %v %v %v", cheap, ref, expensive)
	}
	// Absurdly overpriced -> no demand at all.
	if got := routeDailyDemand(90, 90, distance, refFare*3, baseFare, perKM, poolScale); got != 0 {
		t.Fatalf("overpriced pool = %v, want 0", got)
	}
}
