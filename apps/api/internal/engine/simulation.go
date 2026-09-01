// Package engine — simulation engine (Fase 6): world tick, player simulation, economy.
package engine

import (
	"context"
	"fmt"
	"math"
	"time"
)

// WorldTickResult — hasil world tick.
type WorldTickResult struct {
	TicksProcessed   int    `json:"ticks_processed"`
	PlayersProcessed int    `json:"players_processed"`
	BotsProcessed    int    `json:"bots_processed"`
	GameTimeAfter    string `json:"game_time_after"`
}

// WorldTick — advance season clock, process all players, write world_tick_log.
// Mirror of process_world_tick + process_player_simulation_to_time.
func (e *Engine) WorldTick(ctx context.Context) (*WorldTickResult, error) {
	// 1. Lock & advance season
	var seasonID string
	var gameTimeBefore, gameTimeAfter time.Time
	var tickInterval, timeScale int
	err := e.Pool.QueryRow(ctx, `
		UPDATE season_clock SET current_game_time = current_game_time + (tick_interval_seconds * time_scale_multiplier * interval '1 second')
		WHERE status = 'active' AND pg_try_advisory_xact_lock(hashtext(id::text))
		RETURNING id, current_game_time - (tick_interval_seconds * time_scale_multiplier * interval '1 second'), current_game_time, tick_interval_seconds, time_scale_multiplier`,
	).Scan(&seasonID, &gameTimeBefore, &gameTimeAfter, &tickInterval, &timeScale)
	if err != nil {
		return nil, fmt.Errorf("no active season or lock failed: %w", err)
	}

	// 2. Generate & deactivate events (Go-native)
	e.GenerateGameEvents(ctx, gameTimeAfter)
	e.DeactivateExpiredEvents(ctx, gameTimeAfter)

	// 3. Process REAL players
	players := 0
	rows, _ := e.Pool.Query(ctx, `
		SELECT id, game_current_time FROM users
		WHERE season_id = $1 AND actor_type = 'REAL' AND COALESCE(operational_status, 'Active') != 'Bankrupt'`, seasonID)
	defer rows.Close()
	for rows.Next() {
		var uid string
		var curTime time.Time
		rows.Scan(&uid, &curTime)
		players++
		e.ProcessPlayer(ctx, uid, gameTimeAfter)
	}

	// 4. Process bots (Fase 7 — engine bot)
	bots, _ := e.ProcessBots(ctx)

	// 5. Write world_tick_log
	e.Pool.Exec(ctx, `INSERT INTO world_tick_log (season_id, status, started_at, finished_at, game_time_before, game_time_after, ticks_processed, players_processed, bots_processed)
		VALUES ($1, 'success', NOW(), NOW(), $2, $3, 1, $4, $5)`, seasonID, gameTimeBefore, gameTimeAfter, players, bots)

	// 6. Write finance_snapshots (Fase 6: per active player)
	e.Pool.Exec(ctx, `
		INSERT INTO finance_snapshots (user_id, snapshot_game_time, cash, net_worth, active_routes, fleet_count)
		SELECT u.id, $1, COALESCE((SELECT balance FROM bank_accounts WHERE user_id=u.id AND account_type='operating' LIMIT 1), 0),
		       COALESCE(u.net_worth, 0),
		       (SELECT COUNT(*) FROM route_assignments WHERE user_id=u.id AND COALESCE(status,'active')='active'),
		       (SELECT COUNT(*) FROM fleet_aircraft WHERE user_id=u.id)
		FROM users u WHERE u.season_id = $2
		ON CONFLICT DO NOTHING`, gameTimeAfter, seasonID)

	// 6. Broadcast realtime notifications
	if e.Hub != nil {
		e.Hub.Broadcast("bank_transactions", "INSERT")
		e.Hub.Broadcast("users", "UPDATE")
		e.Hub.BroadcastAll("world_tick")
	}
	_ = timeScale
	_ = tickInterval
	return &WorldTickResult{
		TicksProcessed:   1,
		PlayersProcessed: players,
		BotsProcessed:    bots,
		GameTimeAfter:    gameTimeAfter.Format(time.RFC3339),
	}, nil
}

// ProcessPlayer — mirror of process_player_simulation_to_time inline logic.
func (e *Engine) ProcessPlayer(ctx context.Context, userID string, targetTime time.Time) {
	// load config constants
	fuelPrice := e.getConfigNum(ctx, "fuel_price_per_liter", 0.85)
	crewCost := e.getConfigNum(ctx, "crew_cost_per_hour", 350.0)
	ownedWear := e.getConfigNum(ctx, "owned_wear_per_flight_cycle", 0.50)
	leasedWear := e.getConfigNum(ctx, "leased_wear_per_flight_cycle", 0.70)
	autoRepair := e.getConfigNum(ctx, "maintenance_auto_repair_rate", 0.85)
	bankruptcyThreshold := e.getConfigNum(ctx, "bankruptcy_cash_threshold", -5000000.0)
	cargoPct := e.getConfigNum(ctx, "cargo_revenue_percentage", 0.05)
	ticketBase := e.getConfigNum(ctx, "ticket_base_fare", 50.0)
	ticketKM := e.getConfigNum(ctx, "ticket_per_km_rate", 0.12)
	maxWeekly := e.getConfigNum(ctx, "max_weekly_flights", 168.0)

	// fuel multiplier from events
	var fuelMult, maintMult float64 = 1.0, 1.0
	e.Pool.QueryRow(ctx, `SELECT COALESCE(effect_value, 1.0) FROM game_events WHERE event_type='fuel_shock' AND is_active=true AND effect_type='fuel_price' AND start_game_time<=$1 AND end_game_time>$1 ORDER BY start_game_time DESC LIMIT 1`, targetTime).Scan(&fuelMult)
	e.Pool.QueryRow(ctx, `SELECT COALESCE(effect_value, 1.0) FROM game_events WHERE event_type='maintenance_shock' AND is_active=true AND effect_type='maintenance_cost' AND start_game_time<=$1 AND end_game_time>$1 ORDER BY start_game_time DESC LIMIT 1`, targetTime).Scan(&maintMult)

	// user data
	var userGameTime time.Time
	var autoThreshold float64
	e.Pool.QueryRow(ctx, `SELECT game_current_time, auto_grounding_threshold FROM users WHERE id=$1`, userID).Scan(&userGameTime, &autoThreshold)

	elapsed := targetTime.Sub(userGameTime).Hours() / 24.0
	if elapsed <= 0 {
		// no-op guard
		e.Pool.Exec(ctx, `UPDATE users SET last_active_at=NOW() WHERE id=$1`, userID)
		return
	}
	timeFraction := math.Min(elapsed/7.0, 1.0)
	safetyThreshold := math.Max(autoThreshold, e.getConfigNum(ctx, "absolute_minimum_safety_limit", 30.0))

	// Route loop
	type routeRow struct {
		OriginIATA, DestIATA         string
		DistanceKM, TicketPrice      float64
		FlightsPerWeek               int
		FuelBurnPerKM, SpeedKMH      float64
		TurnaroundHours, Capacity    float64
		LeasePriceMonth, MaintCostHr float64
		AcqType                      string
		OriginDemand, DestDemand     int
		AircraftID                   string
	}
	routes := []routeRow{}
	rrows, _ := e.Pool.Query(ctx, `
		SELECT ur.origin_iata, ur.destination_iata, ur.distance_km, ur.ticket_price, ur.flights_per_week,
		       am.fuel_burn_per_km, am.speed_kmh, am.turnaround_hours, am.capacity,
		       am.lease_price_per_month, am.maintenance_cost_per_hour,
		       fa.acquisition_type, a1.demand_index, a2.demand_index, fa.id
		FROM route_assignments ur
		JOIN fleet_aircraft fa ON fa.id=ur.assigned_aircraft_id
		JOIN aircraft_models am ON am.id=fa.aircraft_model_id
		JOIN airports a1 ON a1.iata=ur.origin_iata
		JOIN airports a2 ON a2.iata=ur.destination_iata
		WHERE ur.user_id=$1 AND ur.status='active' AND fa.status='active' AND fa.condition>=$2`, userID, safetyThreshold)
	if rrows != nil {
		for rrows.Next() {
			var r routeRow
			rrows.Scan(&r.OriginIATA, &r.DestIATA, &r.DistanceKM, &r.TicketPrice, &r.FlightsPerWeek,
				&r.FuelBurnPerKM, &r.SpeedKMH, &r.TurnaroundHours, &r.Capacity,
				&r.LeasePriceMonth, &r.MaintCostHr, &r.AcqType, &r.OriginDemand, &r.DestDemand, &r.AircraftID)
			routes = append(routes, r)
		}
		rrows.Close()
	}

	flightsRun := 0.0
	for _, r := range routes {
		// event multipliers
		demandEvent := 1.0
		e.Pool.QueryRow(ctx, `SELECT COALESCE(effect_value,1.0) FROM game_events WHERE event_type='demand_surge' AND is_active=true AND effect_target IN ($1,$2) AND start_game_time<=$3 AND end_game_time>$3 ORDER BY start_game_time DESC LIMIT 1`, r.OriginIATA, r.DestIATA, targetTime).Scan(&demandEvent)
		capacityEvent := 1.0
		e.Pool.QueryRow(ctx, `SELECT COALESCE(effect_value,1.0) FROM game_events WHERE event_type='weather_disruption' AND is_active=true AND effect_target IN ($1,$2) AND start_game_time<=$3 AND end_game_time>$3 ORDER BY start_game_time DESC LIMIT 1`, r.OriginIATA, r.DestIATA, targetTime).Scan(&capacityEvent)

		flightHours := r.DistanceKM/r.SpeedKMH + r.TurnaroundHours
		if flightHours <= 0 {
			continue
		}
		vMaxWeekly := int(maxWeekly / flightHours)
		flights := r.FlightsPerWeek
		if vMaxWeekly > 0 && flights > vMaxWeekly {
			flights = vMaxWeekly
		}

		airportDemand := calcAirportDemandFactor(r.OriginDemand, r.DestDemand)
		demandMult := calcRouteDemandMultiplier(r.DistanceKM, r.TicketPrice, ticketBase, ticketKM) * demandEvent
		seasonalFactor := 1.0
		effCapacity := math.Floor(r.Capacity * capacityEvent)

		passengers := math.Min(effCapacity, math.Floor(effCapacity*0.95*airportDemand*demandMult*seasonalFactor))
		revenue := float64(flights) * r.TicketPrice * passengers
		fuelCost := float64(flights) * r.DistanceKM * r.FuelBurnPerKM * fuelPrice * fuelMult
		crewCostTotal := float64(flights) * flightHours * crewCost
		maintCost := float64(flights) * r.DistanceKM * r.MaintCostHr * maintMult / r.SpeedKMH
		opsCost := fuelCost + crewCostTotal + maintCost
		leaseCost := 0.0
		if r.AcqType == "lease" {
			leaseCost = r.LeasePriceMonth * (elapsed / 30.0)
		}

		revenue *= timeFraction
		opsCost *= timeFraction
		cargoRev := revenue * cargoPct
		fuelCost *= timeFraction
		crewCostTotal *= timeFraction
		maintCost *= timeFraction

		// write ledger rows
		if revenue > 0 {
			e.Ledger.CreditAccount(ctx, userID, revenue, "revenue", "ticket_revenue",
				fmt.Sprintf("Route %s-%s", r.OriginIATA, r.DestIATA), targetTime)
		}
		if cargoRev > 0 {
			e.Ledger.CreditAccount(ctx, userID, cargoRev, "revenue", "cargo_revenue",
				fmt.Sprintf("Cargo: %s-%s", r.OriginIATA, r.DestIATA), targetTime)
		}
		if fuelCost > 0 {
			e.Ledger.DebitAccount(ctx, userID, fuelCost, "cogs", "fuel_cost",
				fmt.Sprintf("Fuel: %s-%s", r.OriginIATA, r.DestIATA), targetTime)
		}
		if crewCostTotal > 0 {
			e.Ledger.DebitAccount(ctx, userID, crewCostTotal, "cogs", "crew_cost",
				fmt.Sprintf("Crew: %s-%s", r.OriginIATA, r.DestIATA), targetTime)
		}
		if maintCost > 0 {
			e.Ledger.DebitAccount(ctx, userID, maintCost, "cogs", "maintenance_cost",
				fmt.Sprintf("Maintenance: %s-%s", r.OriginIATA, r.DestIATA), targetTime)
		}
		if leaseCost > 0 {
			e.Ledger.DebitAccount(ctx, userID, leaseCost, "opex", "aircraft_lease",
				fmt.Sprintf("Lease: %s-%s", r.OriginIATA, r.DestIATA), targetTime)
		}

		// wear
		wearPerCycle := ownedWear
		if r.AcqType == "lease" {
			wearPerCycle = leasedWear
		}
		wearPerCycle += r.DistanceKM * 0.0001
		grossDamage := wearPerCycle * float64(flights) * timeFraction
		selfHeal := grossDamage * autoRepair
		netDamage := math.Max(0, grossDamage-selfHeal)
		e.Pool.Exec(ctx, `UPDATE fleet_aircraft SET condition = GREATEST(0, condition - $1) WHERE id=$2`, netDamage, r.AircraftID)

		flightsRun += float64(flights) * (elapsed / 7.0)
	}

	// idle lease cost
	var idleLeaseCost float64
	e.Pool.QueryRow(ctx, `
		SELECT COALESCE(SUM(am.lease_price_per_month * ($1 / 30.0)), 0)
		FROM fleet_aircraft fa JOIN aircraft_models am ON am.id=fa.aircraft_model_id
		WHERE fa.user_id=$2 AND fa.acquisition_type='lease' AND NOT EXISTS (
			SELECT 1 FROM route_assignments ra WHERE ra.assigned_aircraft_id=fa.id AND ra.status='active'
		)`, elapsed, userID).Scan(&idleLeaseCost)
	if idleLeaseCost > 0 {
		e.Ledger.DebitAccount(ctx, userID, idleLeaseCost, "opex", "aircraft_lease_idle",
			"Idle lease carrying cost", targetTime)
	}

	// update user game time
	cashAfter, _ := e.Ledger.GetBalance(ctx, userID)
	e.Pool.Exec(ctx, `UPDATE users SET game_current_time=$1, last_active_at=NOW() WHERE id=$2`, targetTime, userID)

	// bankruptcy
	if cashAfter <= bankruptcyThreshold {
		e.applyBankruptcy(ctx, userID)
	}

	// day boundary
	curDay := userGameTime.Truncate(24 * time.Hour)
	targetDay := targetTime.Truncate(24 * time.Hour)
	if curDay != targetDay {
		e.processDayBoundary(ctx, userID, targetTime, elapsed)
	}
}

func (e *Engine) applyBankruptcy(ctx context.Context, userID string) {
	e.Pool.Exec(ctx, `UPDATE users SET operational_status='Bankrupt' WHERE id=$1`, userID)
	e.Pool.Exec(ctx, `UPDATE fleet_aircraft SET status='grounded' WHERE user_id=$1`, userID)
	e.Pool.Exec(ctx, `UPDATE loans SET status='defaulted', remaining_balance=0 WHERE user_id=$1 AND status='active'`, userID)
	e.Pool.Exec(ctx, `UPDATE route_assignments SET status='cancelled' WHERE user_id=$1 AND status='active'`, userID)
}

func (e *Engine) processDayBoundary(ctx context.Context, userID string, gameDate time.Time, elapsedDays float64) {
	// Go-native: credit score + history, loan payments, financing payments
	e.ProcessCreditAtDayBoundary(ctx, userID, gameDate)
	e.ProcessLoanPayments(ctx, userID, gameDate)
	e.ProcessAircraftFinancingPayments(ctx, userID, gameDate)
}

func (e *Engine) getConfigNum(ctx context.Context, key string, fallback float64) float64 {
	var v float64
	err := e.Pool.QueryRow(ctx, `SELECT COALESCE((value#>>'{}')::numeric, $1) FROM game_config WHERE key=$2`, fallback, key).Scan(&v)
	if err != nil {
		return fallback
	}
	return v
}

func calcAirportDemandFactor(originDemand, destDemand int) float64 {
	minFactor := 0.55
	maxFactor := 1.0
	avg := (float64(originDemand) + float64(destDemand)) / 2.0 / 100.0
	return math.Max(minFactor, math.Min(maxFactor, minFactor+avg*(maxFactor-minFactor)))
}

func calcRouteDemandMultiplier(distance, price, baseFare, perKM float64) float64 {
	base := baseFare + distance*perKM
	if base <= 0 {
		return 0
	}
	ratio := price / base
	return math.Max(0, math.Min(1.5, 1.5-0.8*ratio*ratio))
}
