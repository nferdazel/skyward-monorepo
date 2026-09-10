package engine

import (
	"math"
	"testing"
)

// GAME-03: cabin allocation must produce a real trade-off. Premium cabins earn
// more per passenger, but only a limited share of the pool is willing to pay
// premium, so over-configuring premium wastes seats that economy could sell.

const (
	testBaseFare  = 100.0
	testBizMult   = 1.5
	testFirstMult = 2.5
	testEconWill  = 0.80
	testBizWill   = 0.15
	testFirstWill = 0.05
)

func alloc(econ, biz, first int, pool float64) cabinResult {
	return allocateCabins(econ, biz, first, testBaseFare, testBizMult, testFirstMult,
		testEconWill, testBizWill, testFirstWill, pool, 1.0)
}

// A large pool (demand-constrained on the economy side) should reward a
// balanced configuration and punish wasting the pool on unfillable premium.
func TestAllocateCabinsPremiumCapped(t *testing.T) {
	const pool = 1000.0 // plenty of demand

	allEconomy := alloc(180, 0, 0, pool)
	// 80% economy-willing of 1000 = 800, capped by 180 seats.
	if math.Abs(allEconomy.Passengers-180.0) > 0.001 {
		t.Fatalf("all-economy pax = %v, want 180", allEconomy.Passengers)
	}
	if math.Abs(allEconomy.Revenue-180*testBaseFare) > 0.001 {
		t.Fatalf("all-economy revenue = %v, want %v", allEconomy.Revenue, 180*testBaseFare)
	}

	// 15% business-willing of 1000 = 150, but only 18 seats -> 18 filled.
	// 5% first-willing = 50, but only 10 seats -> 10 filled.
	// economy 120 seats fills 120.
	mixed := alloc(120, 18, 10, pool)
	wantPax := 120.0 + 18.0 + 10.0
	if math.Abs(mixed.Passengers-wantPax) > 0.001 {
		t.Fatalf("mixed pax = %v, want %v", mixed.Passengers, wantPax)
	}
	wantRev := 120*testBaseFare + 18*testBaseFare*testBizMult + 10*testBaseFare*testFirstMult
	if math.Abs(mixed.Revenue-wantRev) > 0.001 {
		t.Fatalf("mixed revenue = %v, want %v", mixed.Revenue, wantRev)
	}
}

// With a small pool, the willing share caps premium hard: an all-premium
// configuration wastes nearly the whole pool.
func TestAllocateCabinsSmallPool(t *testing.T) {
	const pool = 100.0

	allFirst := alloc(0, 0, 60, pool)
	// Only 5% of the pool (5 pax) wants first, capped by 60 seats -> 5 pax.
	if math.Abs(allFirst.Passengers-5.0) > 0.001 {
		t.Fatalf("all-first pax = %v, want 5", allFirst.Passengers)
	}
	if math.Abs(allFirst.Revenue-5*testBaseFare*testFirstMult) > 0.001 {
		t.Fatalf("all-first revenue = %v, want %v", allFirst.Revenue, 5*testBaseFare*testFirstMult)
	}

	// Balanced config carries far more passengers on the same pool.
	balanced := alloc(120, 18, 10, pool)
	if balanced.Passengers <= allFirst.Passengers {
		t.Fatalf("balanced pax %v should exceed all-first %v", balanced.Passengers, allFirst.Passengers)
	}
}

// The defining requirement: no single configuration is strictly optimal.
// Slot budget 180 (economy 1, business 2, first 3); both configs below are
// slot-valid. The trade-off is demand-driven:
// - Thin pool: premium-willing demand fits in premium cabins, so a balanced
//   config captures the yield premium and beats all-economy.
// - Thick pool: all-economy sells more (cheaper) seats and beats the balanced
//   config, which sacrificed economy seats for premium ones.
func TestCabinTradeOffIsReal(t *testing.T) {
	// econ 150 + biz 15 (30 slots) = 180 slots.
	thinMix := alloc(150, 15, 0, 100.0)
	thinEcon := alloc(180, 0, 0, 100.0)
	if thinMix.Revenue <= thinEcon.Revenue {
		t.Fatalf("thin pool: balanced premium %v should beat all-economy %v",
			thinMix.Revenue, thinEcon.Revenue)
	}

	// Thick pool: all-economy wins.
	thickMix := alloc(150, 15, 0, 1000.0)
	thickEcon := alloc(180, 0, 0, 1000.0)
	if thickEcon.Revenue <= thickMix.Revenue {
		t.Fatalf("thick pool: all-economy %v should beat balanced premium %v",
			thickEcon.Revenue, thickMix.Revenue)
	}
}

func TestAllocateCabinsUnconfiguredFallsBackToEconomy(t *testing.T) {
	// All-economy fallback is expressed by passing only economy seats.
	got := alloc(180, 0, 0, 1000.0)
	if got.Passengers <= 0 || got.Revenue <= 0 {
		t.Fatalf("unconfigured fallback produced no traffic: %+v", got)
	}
}

func TestAllocateCabinsZeroPool(t *testing.T) {
	got := alloc(180, 18, 10, 0)
	if got.Passengers != 0 || got.Revenue != 0 {
		t.Fatalf("zero pool should yield zero, got %+v", got)
	}
}
