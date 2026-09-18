package engine

import (
	"context"
	"errors"
	"fmt"
	"math"

	"github.com/jackc/pgx/v5"
)

// Route assessment — penilaian ekonomi satu rute yang DIUSULKAN (mungkin belum
// ada di route_assignments), dihitung dengan model yang sama seperti tick:
// routeDailyDemand + allocateCabins + crewCostFor + wear/auto-repair, memakai
// game_config live dan multiplier event dari TickSnapshot.
//
// Ini menggantikan salinan di klien (`route_models.dart`, ~269 LOC) yang membaca
// GameConstants bertanda "fallback": biayanya tidak memasukkan crew, basis
// maintenance-nya memakai turnaround, dan model self-heal wear-nya berbeda
// (jam idle x rate vs gross x auto_repair), jadi angkanya bisa berbeda jauh dari
// yang benar-benar dijalankan tick. Endpoint `GET /routes/assess` menyajikan
// fungsi ini.
type AssessInput struct {
	Origin, Destination string
	DistanceKM          float64
	TicketPrice         float64
	FlightsPerWeek      int
	OriginDemand        int
	DestDemand          int

	// AutoGroundingThreshold — setelan milik pemain; pesawat di bawah nilai ini
	// dianggap grounded dan tidak ikut dinilai (cermin isMaintenanceGrounded).
	AutoGroundingThreshold float64

	// Aircraft — kandidat dari fleet pemain. Yang tidak kompatibel (range kurang
	// atau grounded) disaring di sini supaya klien tidak perlu tahu aturannya.
	Aircraft []AssessAircraft
}

// AssessAircraft — pesawat yang dinilai: model + konfigurasi kabin + kondisinya.
type AssessAircraft struct {
	ID                     string
	ModelName              string
	RangeKM                int
	FuelBurnPerKM          float64
	SpeedKMH               float64
	MaintenanceCostPerHour float64
	Capacity               float64
	TurnaroundHours        float64
	EconomySeats           int
	BusinessSeats          int
	FirstClassSeats        int
	AcquisitionType        string
	LeasePricePerMonth     float64
	Condition              float64
	WearPerFlightCycle     float64 // owned_wear / leased_wear, tanpa jarak
}

// AssessWear — proyeksi keausan satu minggu, memakai rumus tick.
type AssessWear struct {
	PerFlightCycle        float64 `json:"per_flight_cycle"`
	GrossPerWeek          float64 `json:"gross_per_week"`
	SelfHealPerWeek       float64 `json:"self_heal_per_week"`
	NetPerWeek            float64 `json:"net_per_week"`
	ConditionAfterOneWeek float64 `json:"condition_after_one_week"`
}

// AssessViability — band + alasan yang bisa ditampilkan apa adanya.
type AssessViability struct {
	Band    string   `json:"band"`
	Reasons []string `json:"reasons"`
}

// AssessMultipliers — multiplier event yang sedang aktif (1.0 bila tidak ada).
type AssessMultipliers struct {
	Fuel        float64 `json:"fuel"`
	Maintenance float64 `json:"maintenance"`
	Demand      float64 `json:"demand"`
	Capacity    float64 `json:"capacity"`
}

// AssessInputsUsed — nilai config yang dipakai, supaya penyetelan operator
// terlihat dan pertanyaan "kenapa planner beda dengan HUD" bisa dijawab tanpa
// membaca kode.
type AssessInputsUsed struct {
	FuelPricePerLiter         float64 `json:"fuel_price_per_liter"`
	CrewCostPerHour           float64 `json:"crew_cost_per_hour"`
	TicketBaseFare            float64 `json:"ticket_base_fare"`
	TicketPerKMRate           float64 `json:"ticket_per_km_rate"`
	MaxWeeklyFlights          float64 `json:"max_weekly_flights"`
	DemandPoolScale           float64 `json:"demand_pool_scale"`
	BusinessFareMultiplier    float64 `json:"business_fare_multiplier"`
	FirstFareMultiplier       float64 `json:"first_fare_multiplier"`
	EconomyWillingShare       float64 `json:"economy_willing_share"`
	BusinessWillingShare      float64 `json:"business_willing_share"`
	FirstWillingShare         float64 `json:"first_willing_share"`
	CargoRevenuePercentage    float64 `json:"cargo_revenue_percentage"`
	OwnedWearPerFlightCycle   float64 `json:"owned_wear_per_flight_cycle"`
	LeasedWearPerFlightCycle  float64 `json:"leased_wear_per_flight_cycle"`
	MaintenanceAutoRepairRate float64 `json:"maintenance_auto_repair_rate"`
	AutoGroundingThreshold    float64 `json:"auto_grounding_threshold"`
}

// RouteAssessment — satu entri per pesawat kandidat.
type RouteAssessment struct {
	Origin      string  `json:"origin"`
	Destination string  `json:"destination"`
	DistanceKM  float64 `json:"distance_km"`
	TicketPrice float64 `json:"ticket_price"`

	AircraftID    string `json:"aircraft_id"`
	AircraftModel string `json:"aircraft_model"`
	Acquisition   string `json:"acquisition_type"`

	FlightsPerWeekRequested int `json:"flights_per_week_requested"`
	AllocatedFlightsPerWeek int `json:"allocated_flights_per_week"`
	MaxWeeklyFlights        int `json:"max_weekly_flights"`

	FlightDurationHours         float64 `json:"flight_duration_hours"`
	ExpectedPassengersPerFlight float64 `json:"expected_passengers_per_flight"`
	SeatCapacity                int     `json:"seat_capacity"`
	LoadFactorPercent           float64 `json:"load_factor_percent"`

	DirectOperatingCostPerFlight float64 `json:"direct_operating_cost_per_flight"`
	RevenuePerFlight             float64 `json:"revenue_per_flight"`
	ContributionPerFlight        float64 `json:"contribution_per_flight"`
	WeeklyContribution           float64 `json:"weekly_contribution"`

	WeeklyRevenue     float64 `json:"weekly_revenue"`
	WeeklyCargo       float64 `json:"weekly_cargo_revenue"`
	WeeklyFuel        float64 `json:"weekly_fuel_cost"`
	WeeklyCrew        float64 `json:"weekly_crew_cost"`
	WeeklyMaintenance float64 `json:"weekly_maintenance_cost"`
	WeeklyLease       float64 `json:"weekly_lease_cost"`

	Wear        AssessWear        `json:"wear"`
	Viability   AssessViability   `json:"viability"`
	Multipliers AssessMultipliers `json:"multipliers"`
	InputsUsed  AssessInputsUsed  `json:"inputs_used"`
}

// AssessResult — hasil untuk satu rute yang diusulkan.
type AssessResult struct {
	// RouteID hanya diisi oleh `AssessPlayerRoutes` (penilaian rute yang sudah
	// ada); penilaian rute usulan belum punya id.
	RouteID               string            `json:"route_id,omitempty"`
	Origin                string            `json:"origin"`
	Destination           string            `json:"destination"`
	DistanceKM            float64           `json:"distance_km"`
	HasCompatibleAircraft bool              `json:"has_compatible_aircraft"`
	Aircraft              []RouteAssessment `json:"aircraft"`
}

// assessConfig — nilai yang diambil dari config. Dipisah dari TickSnapshot
// supaya fungsi penilaiannya bisa diuji hermetik tanpa database.
type assessConfig struct {
	FuelPrice, CrewCost, TicketBase, TicketKM, MaxWeekly, DemandPoolScale float64
	BusinessFareMult, FirstFareMult                                       float64
	EconomyWilling, BusinessWilling, FirstWilling                         float64
	CargoPct                                                              float64
	OwnedWear, LeasedWear, AutoRepair                                     float64
	Demand                                                                demandCurve
	Crew                                                                  crewScale
}

// assessConfigFrom — jembatan tipis dari snapshot tick ke config penilaian
// (default-nya sengaja sama dengan jalur tick).
func assessConfigFrom(snap *TickSnapshot) assessConfig {
	return assessConfig{
		FuelPrice:        snap.num("fuel_price_per_liter", 0.85),
		CrewCost:         snap.num("crew_cost_per_hour", 350.0),
		TicketBase:       snap.num("ticket_base_fare", 50.0),
		TicketKM:         snap.num("ticket_per_km_rate", 0.12),
		MaxWeekly:        snap.num("max_weekly_flights", 168.0),
		DemandPoolScale:  snap.num("demand_pool_scale", 290.0),
		BusinessFareMult: snap.num("business_fare_multiplier", 1.5),
		FirstFareMult:    snap.num("first_fare_multiplier", 2.5),
		EconomyWilling:   snap.num("economy_willing_share", 0.80),
		BusinessWilling:  snap.num("business_willing_share", 0.15),
		FirstWilling:     snap.num("first_willing_share", 0.05),
		CargoPct:         snap.num("cargo_revenue_percentage", 0.05),
		OwnedWear:        snap.num("owned_wear_per_flight_cycle", 0.50),
		LeasedWear:       snap.num("leased_wear_per_flight_cycle", 0.70),
		AutoRepair:       snap.num("maintenance_auto_repair_rate", 0.85),
		Demand:           demandCurveFrom(snap),
		Crew:             crewScaleFrom(snap),
	}
}

// AssessRoutes — nilai setiap pesawat kandidat untuk satu rute usulan.
// Pesawat yang tidak kompatibel disaring (range kurang atau grounded); kalau
// tidak ada yang tersisa, HasCompatibleAircraft=false dan klien menampilkan
// band "blocked" seperti sebelumnya.
func (e *Engine) AssessRoutes(snap *TickSnapshot, in AssessInput) AssessResult {
	cfg := assessConfigFrom(snap)
	res := AssessResult{
		Origin:      in.Origin,
		Destination: in.Destination,
		DistanceKM:  in.DistanceKM,
	}
	for _, ac := range in.Aircraft {
		if float64(ac.RangeKM) < math.Ceil(in.DistanceKM) {
			continue
		}
		if ac.Condition < in.AutoGroundingThreshold {
			continue
		}
		res.Aircraft = append(res.Aircraft, assessRouteFor(in, ac, cfg, snap))
	}
	res.HasCompatibleAircraft = len(res.Aircraft) > 0
	return res
}

// assessRouteFor — ekonomi satu pesawat. Murni: seluruh input lewat parameter.
func assessRouteFor(in AssessInput, ac AssessAircraft, cfg assessConfig, snap *TickSnapshot) RouteAssessment {
	// Multiplier event dibaca per rute (setiap rute punya origin/destination
	// sendiri). Tanpa snapshot semuanya 1.0 — bukan nilai karangan.
	fuelMult, maintMult := 1.0, 1.0
	demandMult, capacityMult := 1.0, 1.0
	if snap != nil {
		fuelMult, maintMult = snap.fuelMult(), snap.maintMult()
		demandMult = snap.demandMult(in.Origin, in.Destination)
		capacityMult = snap.capacityMult(in.Origin, in.Destination)
	}

	out := RouteAssessment{
		Origin:                  in.Origin,
		Destination:             in.Destination,
		DistanceKM:              in.DistanceKM,
		TicketPrice:             in.TicketPrice,
		AircraftID:              ac.ID,
		AircraftModel:           ac.ModelName,
		Acquisition:             ac.AcquisitionType,
		FlightsPerWeekRequested: in.FlightsPerWeek,
		Multipliers: AssessMultipliers{
			Fuel: fuelMult, Maintenance: maintMult,
			Demand: demandMult, Capacity: capacityMult,
		},
		InputsUsed: assessInputsUsed(cfg, in.AutoGroundingThreshold),
	}

	flightHours := in.DistanceKM/ac.SpeedKMH + ac.TurnaroundHours
	out.FlightDurationHours = flightHours
	if flightHours <= 0 || ac.SpeedKMH <= 0 {
		out.Viability = AssessViability{
			Band:    "blocked",
			Reasons: []string{"aircraft cannot fly this route"},
		}
		return out
	}

	// Cermin tick: `vMaxWeekly := int(maxWeekly / flightHours)`. Sengaja bukan
	// calcMaxWeeklyFlights (yang memotong speed ke int dan dipakai jalur validasi
	// mutasi), supaya angka penilaian sama dengan yang benar-benar dijalankan.
	maxWeekly := int(cfg.MaxWeekly / flightHours)
	out.MaxWeeklyFlights = maxWeekly
	flights := in.FlightsPerWeek
	if maxWeekly > 0 && flights > maxWeekly {
		flights = maxWeekly
	}
	out.AllocatedFlightsPerWeek = flights
	if flights <= 0 {
		out.Viability = AssessViability{
			Band:    "blocked",
			Reasons: []string{"no flights per week allocated"},
		}
		return out
	}

	econSeats, bizSeats, firstSeats := ac.EconomySeats, ac.BusinessSeats, ac.FirstClassSeats
	if econSeats+bizSeats+firstSeats <= 0 {
		econSeats = int(math.Floor(ac.Capacity))
		bizSeats, firstSeats = 0, 0
	}
	seatCapacity := econSeats + bizSeats + firstSeats
	if seatCapacity <= 0 {
		seatCapacity = int(math.Floor(ac.Capacity))
	}
	out.SeatCapacity = seatCapacity

	dailyDemand := routeDailyDemand(in.OriginDemand, in.DestDemand, in.DistanceKM,
		in.TicketPrice, cfg.TicketBase, cfg.TicketKM, cfg.DemandPoolScale, cfg.Demand) * demandMult
	flightsPerDay := float64(flights) / 7.0

	allocation := allocateCabins(
		int(math.Round(float64(econSeats)*flightsPerDay)),
		int(math.Round(float64(bizSeats)*flightsPerDay)),
		int(math.Round(float64(firstSeats)*flightsPerDay)),
		in.TicketPrice, cfg.BusinessFareMult, cfg.FirstFareMult,
		cfg.EconomyWilling, cfg.BusinessWilling, cfg.FirstWilling,
		dailyDemand, capacityMult,
	)

	// Mingguan: pool dibagi ke kabin lalu dikali 7 (sama seperti tick, supaya
	// pendapatan mingguan monoton terhadap pool dan tidak berosilasi karena
	// pembulatan frekuensi pecahan).
	out.WeeklyRevenue = allocation.Revenue * 7.0
	out.WeeklyCargo = out.WeeklyRevenue * cfg.CargoPct
	out.WeeklyFuel = float64(flights) * in.DistanceKM * ac.FuelBurnPerKM * cfg.FuelPrice * fuelMult
	out.WeeklyCrew = float64(flights) * flightHours * crewCostFor(cfg.CrewCost, ac.Capacity, cfg.Crew)
	out.WeeklyMaintenance = float64(flights) * in.DistanceKM * ac.MaintenanceCostPerHour * maintMult / ac.SpeedKMH
	if ac.AcquisitionType == "lease" {
		out.WeeklyLease = ac.LeasePricePerMonth * (7.0 / 30.0)
	}
	weeklyCost := out.WeeklyFuel + out.WeeklyCrew + out.WeeklyMaintenance + out.WeeklyLease
	out.WeeklyContribution = out.WeeklyRevenue + out.WeeklyCargo - weeklyCost

	perFlight := func(amount float64) float64 { return amount / float64(flights) }
	out.DirectOperatingCostPerFlight = perFlight(out.WeeklyFuel + out.WeeklyCrew + out.WeeklyMaintenance)
	out.RevenuePerFlight = perFlight(out.WeeklyRevenue + out.WeeklyCargo)
	out.ContributionPerFlight = perFlight(out.WeeklyContribution)

	if allocation.Passengers > 0 {
		out.ExpectedPassengersPerFlight = allocation.Passengers / flightsPerDay
	}
	if seatCapacity > 0 {
		out.LoadFactorPercent = out.ExpectedPassengersPerFlight / float64(seatCapacity) * 100.0
	}

	// Wear: rumus tick (owned/leased + jarak, self-heal = fraksi dari gross).
	wearPerCycle := ac.WearPerFlightCycle
	if wearPerCycle == 0 {
		wearPerCycle = cfg.OwnedWear
		if ac.AcquisitionType == "lease" {
			wearPerCycle = cfg.LeasedWear
		}
	}
	wearPerCycle += in.DistanceKM * 0.0001
	gross := wearPerCycle * float64(flights)
	selfHeal := gross * cfg.AutoRepair
	net := math.Max(0, gross-selfHeal)
	out.Wear = AssessWear{
		PerFlightCycle:        wearPerCycle,
		GrossPerWeek:          gross,
		SelfHealPerWeek:       selfHeal,
		NetPerWeek:            net,
		ConditionAfterOneWeek: math.Max(0, ac.Condition-net),
	}

	out.Viability = assessViability(out.ContributionPerFlight, out.LoadFactorPercent)
	return out
}

// assessViability — ambang yang sama seperti sebelumnya di klien (40%/65%/12000),
// sekarang di server supaya klien tidak lagi menyimpan angka ajaib.
func assessViability(contributionPerFlight, loadFactorPercent float64) AssessViability {
	var reasons []string
	if contributionPerFlight <= 0 {
		reasons = append(reasons, "contribution per flight is not positive")
	}
	if loadFactorPercent < 40.0 {
		reasons = append(reasons, "load factor below 40%")
	}
	if len(reasons) > 0 {
		return AssessViability{Band: "weak", Reasons: reasons}
	}
	if contributionPerFlight < 12000 {
		reasons = append(reasons, "contribution per flight below 12000")
	}
	if loadFactorPercent < 65.0 {
		reasons = append(reasons, "load factor below 65%")
	}
	if len(reasons) > 0 {
		return AssessViability{Band: "workable", Reasons: reasons}
	}
	return AssessViability{Band: "strong"}
}

func assessInputsUsed(cfg assessConfig, autoGrounding float64) AssessInputsUsed {
	return AssessInputsUsed{
		FuelPricePerLiter:         cfg.FuelPrice,
		CrewCostPerHour:           cfg.CrewCost,
		TicketBaseFare:            cfg.TicketBase,
		TicketPerKMRate:           cfg.TicketKM,
		MaxWeeklyFlights:          cfg.MaxWeekly,
		DemandPoolScale:           cfg.DemandPoolScale,
		BusinessFareMultiplier:    cfg.BusinessFareMult,
		FirstFareMultiplier:       cfg.FirstFareMult,
		EconomyWillingShare:       cfg.EconomyWilling,
		BusinessWillingShare:      cfg.BusinessWilling,
		FirstWillingShare:         cfg.FirstWilling,
		CargoRevenuePercentage:    cfg.CargoPct,
		OwnedWearPerFlightCycle:   cfg.OwnedWear,
		LeasedWearPerFlightCycle:  cfg.LeasedWear,
		MaintenanceAutoRepairRate: cfg.AutoRepair,
		AutoGroundingThreshold:    autoGrounding,
	}
}

// AssessRouteParams — permintaan `GET /routes/assess`. Jarak dan indeks
// permintaan TIDAK dikirim klien: keduanya diambil dari tabel `airports` supaya
// penilaian memakai angka yang sama dengan tick.
type AssessRouteParams struct {
	OriginIATA      string  `json:"origin_iata"`
	DestinationIATA string  `json:"destination_iata"`
	TicketPrice     float64 `json:"ticket_price"`
	FlightsPerWeek  int     `json:"flights_per_week"`
	// AircraftID opsional: kosong berarti nilai semua pesawat yang kompatibel.
	AircraftID string `json:"aircraft_id"`
}

// AssessRoute — nilai satu rute usulan untuk pemain `userID`.
//
// Sumber angkanya sama dengan tick: `airports.demand_index` + haversine untuk
// jarak, `game_config` live + event aktif lewat `LoadTickSnapshot`, dan rumus
// `routeDailyDemand`/`allocateCabins`/wear yang dipakai `ProcessPlayer`.
// Handler hanya memvalidasi bentuk permintaan; geografi dan ekonomi di sini.
func (e *Engine) AssessRoute(ctx context.Context, userID string, p AssessRouteParams) (*AssessResult, error) {
	if p.OriginIATA == "" || p.DestinationIATA == "" || p.OriginIATA == p.DestinationIATA {
		return nil, ErrAssessInvalid
	}
	if p.TicketPrice <= 0 || p.FlightsPerWeek < 1 || p.FlightsPerWeek > 168 {
		return nil, ErrAssessInvalid
	}

	var oLat, oLon float64
	var oDemand int
	if err := e.Pool.QueryRow(ctx,
		`SELECT latitude, longitude, demand_index FROM airports WHERE iata=$1`, p.OriginIATA).
		Scan(&oLat, &oLon, &oDemand); err != nil {
		return nil, ErrAssessAirportNotFound
	}
	var dLat, dLon float64
	var dDemand int
	if err := e.Pool.QueryRow(ctx,
		`SELECT latitude, longitude, demand_index FROM airports WHERE iata=$1`, p.DestinationIATA).
		Scan(&dLat, &dLon, &dDemand); err != nil {
		return nil, ErrAssessAirportNotFound
	}

	gameTime, err := e.Ledger.GetUserGameTime(ctx, userID)
	if err != nil {
		return nil, fmt.Errorf("assess route: game time: %w", err)
	}
	snap, err := e.LoadTickSnapshot(ctx, gameTime)
	if err != nil {
		return nil, fmt.Errorf("assess route: snapshot: %w", err)
	}

	// Setelan pemain; NULL atau tidak ada berarti tanpa ambang grounding.
	var threshold *float64
	if err := e.Pool.QueryRow(ctx,
		`SELECT auto_grounding_threshold FROM users WHERE id=$1`, userID).Scan(&threshold); err != nil && err != pgx.ErrNoRows {
		return nil, fmt.Errorf("assess route: grounding threshold: %w", err)
	}
	autoGrounding := 0.0
	if threshold != nil {
		autoGrounding = *threshold
	}

	in := AssessInput{
		Origin:                 p.OriginIATA,
		Destination:            p.DestinationIATA,
		DistanceKM:             haversine(oLat, oLon, dLat, dLon),
		TicketPrice:            p.TicketPrice,
		FlightsPerWeek:         p.FlightsPerWeek,
		OriginDemand:           oDemand,
		DestDemand:             dDemand,
		AutoGroundingThreshold: autoGrounding,
	}

	// Kandidat: pesawat pemain (atau satu pesawat bila klien menyebut id-nya).
	fleet, err := e.loadAssessAircraft(ctx, userID, p.AircraftID, snap)
	if err != nil {
		return nil, err
	}
	in.Aircraft = fleet

	res := e.AssessRoutes(snap, in)
	return &res, nil
}

// loadAssessAircraft — pesawat pemain yang ikut dinilai, dengan basis keausan
// per siklus dari config (dipegang di sini supaya pemanggil tidak perlu tahu).
// `onlyID` kosong berarti seluruh armada.
func (e *Engine) loadAssessAircraft(ctx context.Context, userID, onlyID string, snap *TickSnapshot) ([]AssessAircraft, error) {
	rows, err := e.Pool.Query(ctx, `
		SELECT f.id, m.model_name, m.range_km, m.fuel_burn_per_km, m.speed_kmh,
		       m.maintenance_cost_per_hour, m.capacity, m.turnaround_hours,
		       f.economy_seats, f.business_seats, f.first_class_seats,
		       f.acquisition_type, COALESCE(m.lease_price_per_month,0), f.condition,
		       CASE WHEN f.acquisition_type='lease' THEN $2::float8 ELSE $3::float8 END
		FROM fleet_aircraft f
		JOIN aircraft_models m ON m.id = f.aircraft_model_id
		WHERE f.user_id=$1::uuid AND f.status <> 'sold'
		  AND ($4::text = '' OR f.id::text = $4::text)
		ORDER BY f.acquired_game_date DESC NULLS LAST`,
		userID,
		snap.num("leased_wear_per_flight_cycle", 0.70),
		snap.num("owned_wear_per_flight_cycle", 0.50),
		onlyID)
	if err != nil {
		return nil, fmt.Errorf("assess route: fleet: %w", err)
	}
	defer rows.Close()
	var out []AssessAircraft
	for rows.Next() {
		var ac AssessAircraft
		if err := rows.Scan(&ac.ID, &ac.ModelName, &ac.RangeKM, &ac.FuelBurnPerKM, &ac.SpeedKMH,
			&ac.MaintenanceCostPerHour, &ac.Capacity, &ac.TurnaroundHours,
			&ac.EconomySeats, &ac.BusinessSeats, &ac.FirstClassSeats,
			&ac.AcquisitionType, &ac.LeasePricePerMonth, &ac.Condition,
			&ac.WearPerFlightCycle); err != nil {
			return nil, fmt.Errorf("assess route: fleet scan: %w", err)
		}
		out = append(out, ac)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("assess route: fleet iteration: %w", err)
	}
	return out, nil
}

// ErrAssessInvalid — permintaan tidak valid (dipetakan handler ke 400).
var ErrAssessInvalid = errors.New("assess route: invalid request")

// ErrAssessAirportNotFound — bandara tidak dikenal (dipetakan handler ke 404).
var ErrAssessAirportNotFound = errors.New("assess route: airport not found")

// AssessPlayerRoutes — nilai semua rute aktif pemain dalam satu panggilan.
//
// Dipakai dashboard, yang butuh kontribusi mingguan seluruh rute sekaligus
// (mis. KPI "top yield"). Berbeda dari `AssessRoute` yang menjawab "kalau saya
// pakai pesawat mana pun", di sini setiap rute dinilai dengan pesawat yang
// MEMANG di-assign ke rute itu — itulah angka yang akan dijalankan tick.
//
// Query-nya tetap lima terlepas dari jumlah rute: config + event (snapshot),
// ambang grounding, armada, dan rute.
func (e *Engine) AssessPlayerRoutes(ctx context.Context, userID string) ([]AssessResult, error) {
	gameTime, err := e.Ledger.GetUserGameTime(ctx, userID)
	if err != nil {
		return nil, fmt.Errorf("assess routes: game time: %w", err)
	}
	snap, err := e.LoadTickSnapshot(ctx, gameTime)
	if err != nil {
		return nil, fmt.Errorf("assess routes: snapshot: %w", err)
	}

	var threshold *float64
	if err := e.Pool.QueryRow(ctx,
		`SELECT auto_grounding_threshold FROM users WHERE id=$1`, userID).Scan(&threshold); err != nil && err != pgx.ErrNoRows {
		return nil, fmt.Errorf("assess routes: grounding threshold: %w", err)
	}
	autoGrounding := 0.0
	if threshold != nil {
		autoGrounding = *threshold
	}

	fleet, err := e.loadAssessAircraft(ctx, userID, "", snap)
	if err != nil {
		return nil, err
	}
	byID := make(map[string]AssessAircraft, len(fleet))
	for _, ac := range fleet {
		byID[ac.ID] = ac
	}

	rows, err := e.Pool.Query(ctx, `
		SELECT r.id, r.origin_iata, r.destination_iata, r.distance_km,
		       r.ticket_price, r.flights_per_week, COALESCE(r.assigned_aircraft_id::text,''),
		       o.demand_index, d.demand_index,
		       o.latitude, o.longitude, d.latitude, d.longitude
		FROM route_assignments r
		JOIN airports o ON o.iata = r.origin_iata
		JOIN airports d ON d.iata = r.destination_iata
		WHERE r.user_id=$1::uuid AND r.status='active'
		ORDER BY r.origin_iata, r.destination_iata`, userID)
	if err != nil {
		return nil, fmt.Errorf("assess routes: routes: %w", err)
	}
	defer rows.Close()

	var out []AssessResult
	for rows.Next() {
		var (
			routeID, origin, dest, assignedID string
			distance, price                   float64
			flights, oDemand, dDemand         int
			oLat, oLon, dLat, dLon            float64
		)
		if err := rows.Scan(&routeID, &origin, &dest, &distance, &price, &flights,
			&assignedID, &oDemand, &dDemand, &oLat, &oLon, &dLat, &dLon); err != nil {
			return nil, fmt.Errorf("assess routes: route scan: %w", err)
		}
		if distance <= 0 {
			distance = haversine(oLat, oLon, dLat, dLon)
		}
		in := AssessInput{
			Origin:                 origin,
			Destination:            dest,
			DistanceKM:             distance,
			TicketPrice:            price,
			FlightsPerWeek:         flights,
			OriginDemand:           oDemand,
			DestDemand:             dDemand,
			AutoGroundingThreshold: autoGrounding,
		}
		// Hanya pesawat yang benar-benar terbang di rute ini, dan TANPA saringan
		// range/grounding: untuk rute yang sudah ada, angka tetap dibutuhkan
		// supaya dashboard bisa menilainya, sedangkan "grounded" adalah predikat
		// yang sudah dipegang klien dari kondisi pesawatnya. Rute tanpa pesawat
		// tetap dikembalikan tanpa entri.
		res := AssessResult{
			RouteID:     routeID,
			Origin:      origin,
			Destination: dest,
			DistanceKM:  distance,
		}
		if ac, ok := byID[assignedID]; ok && assignedID != "" {
			res.Aircraft = []RouteAssessment{assessRouteFor(in, ac, assessConfigFrom(snap), snap)}
			res.HasCompatibleAircraft = true
		}
		out = append(out, res)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("assess routes: route iteration: %w", err)
	}
	return out, nil
}
