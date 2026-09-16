package engine

import (
	"math"
	"testing"
)

// assessTestConfig — config dasar untuk pengujian; nilainya sengaja bulat.
func assessTestConfig() assessConfig {
	return assessConfig{
		FuelPrice:        1.0,
		CrewCost:         100.0,
		TicketBase:       50.0,
		TicketKM:         0.10,
		MaxWeekly:        168.0,
		DemandPoolScale:  300.0,
		BusinessFareMult: 1.5,
		FirstFareMult:    2.5,
		EconomyWilling:   0.80,
		BusinessWilling:  0.15,
		FirstWilling:     0.05,
		CargoPct:         0.05,
		OwnedWear:        0.50,
		LeasedWear:       0.70,
		AutoRepair:       0.85,
	}
}

func assessTestAircraft() AssessAircraft {
	return AssessAircraft{
		ID:                     "ac-1",
		ModelName:              "Testjet 200",
		RangeKM:                3000,
		FuelBurnPerKM:          0.004,
		SpeedKMH:               800,
		MaintenanceCostPerHour: 120,
		Capacity:               180,
		TurnaroundHours:        1.0,
		EconomySeats:           160,
		BusinessSeats:          16,
		FirstClassSeats:        4,
		AcquisitionType:        "owned",
		Condition:              100,
	}
}

func assessTestInput() AssessInput {
	return AssessInput{
		Origin:                 "CGK",
		Destination:            "DPS",
		DistanceKM:             1000,
		TicketPrice:            120,
		FlightsPerWeek:         7,
		OriginDemand:           80,
		DestDemand:             70,
		AutoGroundingThreshold: 40,
		Aircraft:               []AssessAircraft{assessTestAircraft()},
	}
}

// TestAssessRouteInvariants — relasi antar field harus konsisten, terlepas dari
// nilai model permintaan. Ini yang membuat angka penilaian bisa dipakai klien.
func TestAssessRouteInvariants(t *testing.T) {
	in := assessTestInput()
	got := assessRouteFor(in, assessTestAircraft(), assessTestConfig(), nil)

	flights := float64(got.AllocatedFlightsPerWeek)
	if flights <= 0 {
		t.Fatalf("allocated flights = %v, want > 0", got.AllocatedFlightsPerWeek)
	}
	if got.MaxWeeklyFlights <= 0 {
		t.Fatalf("max weekly flights = %v, want > 0", got.MaxWeeklyFlights)
	}

	weeklyCost := got.WeeklyFuel + got.WeeklyCrew + got.WeeklyMaintenance + got.WeeklyLease
	if want := got.WeeklyRevenue + got.WeeklyCargo - weeklyCost; math.Abs(got.WeeklyContribution-want) > 1e-9 {
		t.Errorf("weekly contribution = %v, want revenue+cargo-cost = %v", got.WeeklyContribution, want)
	}
	if got.WeeklyCrew <= 0 {
		t.Error("weekly crew cost = 0: crew cost is part of the tick and must be charged")
	}
	if got.WeeklyCargo != got.WeeklyRevenue*assessTestConfig().CargoPct {
		t.Errorf("cargo = %v, want %v", got.WeeklyCargo, got.WeeklyRevenue*assessTestConfig().CargoPct)
	}
	if want := (got.WeeklyFuel + got.WeeklyCrew + got.WeeklyMaintenance) / flights; math.Abs(got.DirectOperatingCostPerFlight-want) > 1e-9 {
		t.Errorf("direct cost/flight = %v, want %v (lease tidak termasuk)", got.DirectOperatingCostPerFlight, want)
	}
	if want := (got.WeeklyRevenue + got.WeeklyCargo) / flights; math.Abs(got.RevenuePerFlight-want) > 1e-9 {
		t.Errorf("revenue/flight = %v, want %v", got.RevenuePerFlight, want)
	}
	if want := got.WeeklyContribution / flights; math.Abs(got.ContributionPerFlight-want) > 1e-9 {
		t.Errorf("contribution/flight = %v, want %v", got.ContributionPerFlight, want)
	}
	if got.SeatCapacity != 180 {
		t.Errorf("seat capacity = %d, want 180 (160+16+4)", got.SeatCapacity)
	}
	if got.LoadFactorPercent < 0 || got.LoadFactorPercent > 100 {
		t.Errorf("load factor = %v, want 0..100", got.LoadFactorPercent)
	}
	if want := got.ExpectedPassengersPerFlight / float64(got.SeatCapacity) * 100; math.Abs(got.LoadFactorPercent-want) > 1e-9 {
		t.Errorf("load factor = %v, want %v", got.LoadFactorPercent, want)
	}
	if got.AllocatedFlightsPerWeek > in.FlightsPerWeek {
		t.Errorf("allocated %d > requested %d", got.AllocatedFlightsPerWeek, in.FlightsPerWeek)
	}
}

// TestAssessRouteLeaseCost — sewa dibebankan mingguan (7/30 bulan), dan hanya
// untuk pesawat ber-acquisition_type lease.
func TestAssessRouteLeaseCost(t *testing.T) {
	ac := assessTestAircraft()
	ac.AcquisitionType = "lease"
	ac.LeasePricePerMonth = 3000

	leased := assessRouteFor(assessTestInput(), ac, assessTestConfig(), nil)
	if want := 3000 * 7.0 / 30.0; math.Abs(leased.WeeklyLease-want) > 1e-9 {
		t.Errorf("leased weekly lease = %v, want %v", leased.WeeklyLease, want)
	}

	owned := assessRouteFor(assessTestInput(), assessTestAircraft(), assessTestConfig(), nil)
	if owned.WeeklyLease != 0 {
		t.Errorf("owned weekly lease = %v, want 0", owned.WeeklyLease)
	}
	if owned.InputsUsed.LeasedWearPerFlightCycle == 0 {
		t.Error("inputs_used should expose the leased wear value too")
	}
}

// TestAssessRouteFuelShock — multiplier event dari snapshot menaikkan biaya
// bahan bakar saja, bukan pendapatan.
func TestAssessRouteFuelShock(t *testing.T) {
	base := assessRouteFor(assessTestInput(), assessTestAircraft(), assessTestConfig(), nil)

	snap := &TickSnapshot{events: []activeEvent{
		{eventType: "fuel_shock", effectType: pstr("fuel_price"), value: 1.5},
	}}
	shocked := assessRouteFor(assessTestInput(), assessTestAircraft(), assessTestConfig(), snap)

	if math.Abs(shocked.WeeklyFuel-base.WeeklyFuel*1.5) > 1e-9 {
		t.Errorf("fuel under shock = %v, want %v", shocked.WeeklyFuel, base.WeeklyFuel*1.5)
	}
	if math.Abs(shocked.WeeklyRevenue-base.WeeklyRevenue) > 1e-9 {
		t.Errorf("revenue changed with a fuel shock: %v vs %v", shocked.WeeklyRevenue, base.WeeklyRevenue)
	}
	if shocked.Multipliers.Fuel != 1.5 {
		t.Errorf("multipliers.fuel = %v, want 1.5", shocked.Multipliers.Fuel)
	}
	if base.Multipliers.Fuel != 1.0 {
		t.Errorf("tanpa snapshot multiplier.fuel = %v, want 1.0", base.Multipliers.Fuel)
	}
}

// TestAssessRouteWearMatchesTick — gross = wear/cycle x penerbangan, self-heal
// adalah fraksi dari gross (85%), bukan jam idle x rate seperti versi klien.
func TestAssessRouteWearMatchesTick(t *testing.T) {
	in := assessTestInput()
	cfg := assessTestConfig()
	got := assessRouteFor(in, assessTestAircraft(), cfg, nil)

	flights := float64(got.AllocatedFlightsPerWeek)
	wantPerCycle := cfg.OwnedWear + in.DistanceKM*0.0001
	if math.Abs(got.Wear.PerFlightCycle-wantPerCycle) > 1e-9 {
		t.Errorf("wear/cycle = %v, want %v", got.Wear.PerFlightCycle, wantPerCycle)
	}
	wantGross := wantPerCycle * flights
	if math.Abs(got.Wear.GrossPerWeek-wantGross) > 1e-9 {
		t.Errorf("gross wear = %v, want %v", got.Wear.GrossPerWeek, wantGross)
	}
	if math.Abs(got.Wear.SelfHealPerWeek-wantGross*cfg.AutoRepair) > 1e-9 {
		t.Errorf("self heal = %v, want %v", got.Wear.SelfHealPerWeek, wantGross*cfg.AutoRepair)
	}
	wantNet := wantGross - wantGross*cfg.AutoRepair
	if math.Abs(got.Wear.NetPerWeek-wantNet) > 1e-9 {
		t.Errorf("net wear = %v, want %v", got.Wear.NetPerWeek, wantNet)
	}
	if want := 100 - wantNet; math.Abs(got.Wear.ConditionAfterOneWeek-want) > 1e-9 {
		t.Errorf("condition after a week = %v, want %v", got.Wear.ConditionAfterOneWeek, want)
	}
}

// TestAssessRoutesFiltersIncompatible — range kurang atau grounded tidak dinilai,
// dan hasilnya menandai bahwa tidak ada pesawat kompatibel.
func TestAssessRoutesFiltersIncompatible(t *testing.T) {
	e := &Engine{}

	shortRange := assessTestAircraft()
	shortRange.ID = "ac-short"
	shortRange.RangeKM = 500

	grounded := assessTestAircraft()
	grounded.ID = "ac-grounded"
	grounded.Condition = 20

	in := assessTestInput()
	in.Aircraft = []AssessAircraft{shortRange, grounded, assessTestAircraft()}

	got := e.AssessRoutes(nil, in)
	if !got.HasCompatibleAircraft {
		t.Fatal("has_compatible_aircraft = false, want true (satu pesawat layak)")
	}
	if len(got.Aircraft) != 1 || got.Aircraft[0].AircraftID != "ac-1" {
		t.Fatalf("dinilai = %+v, want hanya ac-1", got.Aircraft)
	}

	in.Aircraft = []AssessAircraft{shortRange, grounded}
	none := e.AssessRoutes(nil, in)
	if none.HasCompatibleAircraft || len(none.Aircraft) != 0 {
		t.Errorf("tanpa pesawat layak: %+v", none)
	}
}

// TestAssessViabilityBands — ambang dipindah dari klien ke server apa adanya.
func TestAssessViabilityBands(t *testing.T) {
	cases := []struct {
		name         string
		contribution float64
		loadFactor   float64
		want         string
	}{
		{"contribution negatif", -1, 90, "weak"},
		{"load factor di bawah 40", 50000, 39.9, "weak"},
		{"contribution di bawah 12000", 11999, 80, "workable"},
		{"load factor di bawah 65", 50000, 64.9, "workable"},
		{"keduanya bagus", 12000, 65, "strong"},
	}
	for _, c := range cases {
		got := assessViability(c.contribution, c.loadFactor)
		if got.Band != c.want {
			t.Errorf("%s: band = %q, want %q", c.name, got.Band, c.want)
		}
		if got.Band != "strong" && len(got.Reasons) == 0 {
			t.Errorf("%s: band %q harus menyertakan alasan", c.name, got.Band)
		}
		if got.Band == "strong" && len(got.Reasons) != 0 {
			t.Errorf("%s: band strong tidak boleh punya alasan: %v", c.name, got.Reasons)
		}
	}
}

// TestAssessRouteBlocked — keadaan yang tidak bisa dinilai diberi band blocked.
func TestAssessRouteBlocked(t *testing.T) {
	ac := assessTestAircraft()
	ac.SpeedKMH = 0
	got := assessRouteFor(assessTestInput(), ac, assessTestConfig(), nil)
	if got.Viability.Band != "blocked" {
		t.Errorf("speed 0: band = %q, want blocked", got.Viability.Band)
	}

	// Kapasitas kabin nol jatuh ke kapasitas fisik, bukan nol.
	ac = assessTestAircraft()
	ac.EconomySeats, ac.BusinessSeats, ac.FirstClassSeats = 0, 0, 0
	fallback := assessRouteFor(assessTestInput(), ac, assessTestConfig(), nil)
	if fallback.SeatCapacity != 180 {
		t.Errorf("tanpa konfigurasi kabin: seat capacity = %d, want 180", fallback.SeatCapacity)
	}
}

// TestAssessConfigFromSnapshot — jembatan snapshot memakai nilai config dan
// membiarkan multiplier per rute diambil kemudian.
func TestAssessConfigFromSnapshot(t *testing.T) {
	snap := &TickSnapshot{cfg: map[string]float64{
		"fuel_price_per_liter":         2.5,
		"crew_cost_per_hour":           400,
		"ticket_base_fare":             60,
		"ticket_per_km_rate":           0.2,
		"max_weekly_flights":           100,
		"demand_pool_scale":            310,
		"business_fare_multiplier":     1.6,
		"first_fare_multiplier":        2.6,
		"economy_willing_share":        0.7,
		"business_willing_share":       0.2,
		"first_willing_share":          0.1,
		"cargo_revenue_percentage":     0.06,
		"owned_wear_per_flight_cycle":  0.4,
		"leased_wear_per_flight_cycle": 0.6,
		"maintenance_auto_repair_rate": 0.5,
	}}
	cfg := assessConfigFrom(snap)

	if cfg.FuelPrice != 2.5 || cfg.CrewCost != 400 || cfg.MaxWeekly != 100 {
		t.Errorf("config tidak terpakai: %+v", cfg)
	}
	if cfg.OwnedWear != 0.4 || cfg.LeasedWear != 0.6 || cfg.AutoRepair != 0.5 {
		t.Errorf("config wear tidak terpakai: %+v", cfg)
	}
}
