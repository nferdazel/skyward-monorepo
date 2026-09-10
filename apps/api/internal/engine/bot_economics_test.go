package engine

import (
	"math"
	"testing"
)

// GAME-25: bot route economics share the GAME-02 demand pool + GAME-03 cabin
// allocation with the player simulation. These tests exercise routeWeeklyProfit
// directly (the function routePerformance calls) and pin the model behaviour.

func testRouteConfig() routePerfConfig {
	return routePerfConfig{
		FuelPrice:        0.85,
		CrewCost:         350.0,
		TicketBase:       50.0,
		TicketKM:         0.12,
		MaxWeekly:        168.0,
		DemandPoolScale:  290.0,
		BusinessFareMult: testBizMult,
		FirstFareMult:    testFirstMult,
		EconomyWilling:   testEconWill,
		BusinessWilling:  testBizWill,
		FirstWilling:     testFirstWill,
		CargoPct:         0.05,
	}
}

func testRouteParams() routePerfParams {
	return routePerfParams{
		DistanceKM:      1200,
		TicketPrice:     180,
		FlightsPerWeek:  14,
		FuelBurnPerKM:   0.03,
		SpeedKMH:        800,
		MaintCostHr:     600,
		Capacity:        176,
		TurnaroundHours: 1.0,
		OriginDemand:    80,
		DestDemand:      70,
		EconomySeats:    160,
		BusinessSeats:   12,
		FirstClassSeats: 4,
		AcqType:         "owned",
		LeasePriceMonth: 0,
	}
}

func TestRouteWeeklyProfitUsesDemandPoolAndCabins(t *testing.T) {
	p := testRouteParams()
	cfg := testRouteConfig()
	profit := routeWeeklyProfit(p, cfg)

	// Revenue must be derived from the demand pool, not raw capacity. Compute
	// the expected pool and allocation independently and compare.
	pool := routeDailyDemand(p.OriginDemand, p.DestDemand, p.DistanceKM,
		p.TicketPrice, cfg.TicketBase, cfg.TicketKM, cfg.DemandPoolScale)
	allocation := allocateCabins(
		int(math.Round(float64(p.EconomySeats)*2)),
		int(math.Round(float64(p.BusinessSeats)*2)),
		int(math.Round(float64(p.FirstClassSeats)*2)),
		p.TicketPrice, cfg.BusinessFareMult, cfg.FirstFareMult,
		cfg.EconomyWilling, cfg.BusinessWilling, cfg.FirstWilling, pool, 1.0,
	)
	revenue := allocation.Revenue * 7.0 * (1 + cfg.CargoPct)
	flightHours := p.DistanceKM/p.SpeedKMH + 1.0
	flights := math.Min(p.FlightsPerWeek, cfg.MaxWeekly/flightHours)
	expected := revenue -
		flights*p.DistanceKM*p.FuelBurnPerKM*cfg.FuelPrice -
		flights*flightHours*crewCostFor(cfg.CrewCost, p.Capacity) -
		flights*p.DistanceKM*p.MaintCostHr/p.SpeedKMH

	if math.Abs(profit-expected) > 0.01 {
		t.Fatalf("routeWeeklyProfit = %.2f, want %.2f", profit, expected)
	}
	if profit <= 0 {
		t.Fatalf("expected profitable reference route, got %.2f", profit)
	}
}

// A premium-configured aircraft should earn more than the same route flown
// all-economy when demand is plentiful — proving cabin mix feeds into bot
// economics (the old formula was economy-only).
func TestRouteWeeklyProfitReflectsPremiumCabin(t *testing.T) {
	cfg := testRouteConfig()
	economy := testRouteParams()
	economy.BusinessSeats, economy.FirstClassSeats = 0, 0
	economy.EconomySeats = 176

	premium := testRouteParams()

	econProfit := routeWeeklyProfit(economy, cfg)
	premProfit := routeWeeklyProfit(premium, cfg)
	if premProfit <= econProfit {
		t.Fatalf("premium config should out-earn all-economy when demand is ample: premium=%.2f economy=%.2f",
			premProfit, econProfit)
	}
}

// Leased aircraft must carry a lease cost so bot pruning does not treat them as
// free; a monthly lease materially lowers weekly profit versus an owned frame.
func TestRouteWeeklyProfitIncludesLeaseCost(t *testing.T) {
	cfg := testRouteConfig()
	owned := testRouteParams()
	leased := testRouteParams()
	leased.AcqType = "lease"
	leased.LeasePriceMonth = 300000

	if routeWeeklyProfit(leased, cfg) >= routeWeeklyProfit(owned, cfg) {
		t.Fatalf("leased route should cost more than owned")
	}
}

// Unconfigured aircraft fall back to all-economy using the model capacity,
// matching ProcessPlayer.
func TestRouteWeeklyProfitUnconfiguredFallsBackToEconomy(t *testing.T) {
	cfg := testRouteConfig()
	p := testRouteParams()
	p.EconomySeats, p.BusinessSeats, p.FirstClassSeats = 0, 0, 0

	allEconomy := p
	allEconomy.EconomySeats = int(math.Floor(p.Capacity))

	if math.Abs(routeWeeklyProfit(p, cfg)-routeWeeklyProfit(allEconomy, cfg)) > 0.01 {
		t.Fatalf("unconfigured should equal all-economy fallback")
	}
}

// The turnaround value must feed the weekly-frequency cap (AVIATION-13). Under
// the GAME-02 pool model revenue is demand-limited, so at a fixed capped
// frequency a slow aircraft flies fewer, more expensive-to-schedule cycles;
// what we assert here is the mechanical effect: a turnaround change alters the
// computed profit (i.e. the value is actually used, not ignored).
func TestRouteWeeklyProfitUsesTurnaround(t *testing.T) {
	cfg := testRouteConfig()
	quick := testRouteParams()
	quick.TurnaroundHours = 0.5
	quick.FlightsPerWeek = 168
	slow := testRouteParams()
	slow.TurnaroundHours = 2.0
	slow.FlightsPerWeek = 168

	if math.Abs(routeWeeklyProfit(quick, cfg)-routeWeeklyProfit(slow, cfg)) < 0.01 {
		t.Fatalf("turnaround must affect route economics (value appears unused)")
	}
}
