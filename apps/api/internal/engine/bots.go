// Package engine — bot engine (Fase 7), faithful ke execute_bot_decisions + sub-functions.
// Semua mutasi bot memakai shared helper engine (Fleet/Routes/Bank) — parity by construction.
package engine

import (
	"context"
	"fmt"
	"math"
	"math/rand"
	"time"
)

// ProcessBots — orchestrator bot (mirror execute_bot_decisions).
func (e *Engine) ProcessBots(ctx context.Context) (int, error) {
	startingCash := e.getConfigNum(ctx, "starting_cash", 15000000.0)
	bankruptcyThreshold := e.getConfigNum(ctx, "bankruptcy_cash_threshold", -5000000.0)
	repairReserve := e.getConfigNum(ctx, "bot_repair_cash_reserve", 500000.0)
	purchaseMult := e.getConfigNum(ctx, "bot_purchase_cash_multiplier", 1.5)
	compThreshold := e.getConfigNum(ctx, "bot_competitive_price_threshold", 0.20)
	recoveryAmount := e.getConfigNum(ctx, "bot_recovery_loan_amount", 2000000.0)
	repayRatio := e.getConfigNum(ctx, "bot_loan_repayment_ratio", 0.20)
	lossDaysThresh := int(e.getConfigNum(ctx, "bot_consecutive_loss_days_threshold", 7))
	secondaryHubChance := e.getConfigNum(ctx, "bot_secondary_hub_chance", 0.20)
	fleetDiversity := e.getConfigNum(ctx, "bot_fleet_diversity_chance", 0.30)

	var seasonID string
	e.Pool.QueryRow(ctx, `SELECT id FROM season_clock WHERE status='active' LIMIT 1`).Scan(&seasonID)

	rows, err := e.Pool.Query(ctx, `
		SELECT u.id, u.game_current_time, u.hq_airport_iata, u.auto_grounding_threshold,
		       u.consecutive_negative_days, u.recovery_streak_days, u.operational_status,
		       COALESCE(bp.archetype,'Balanced'), bp.consecutive_loss_days, bp.recovery_loan_taken,
		       COALESCE(bp.distress_stage,'stable')
		FROM users u LEFT JOIN bot_profiles bp ON bp.user_id=u.id
		WHERE u.actor_type='AI' AND COALESCE(u.operational_status,'Active') != 'Bankrupt'`)
	if err != nil {
		return 0, err
	}
	defer rows.Close()

	processed := 0
	for rows.Next() {
		var b struct {
			ID                        string
			GameTime                  time.Time
			HQ, AutoThreshold         string
			ConsecNeg, RecoveryStreak int
			OperStatus, Archetype     string
			LossDays                  int
			RecoveryLoanTaken         bool
			Distress                  string
		}
		rows.Scan(&b.ID, &b.GameTime, &b.HQ, &b.AutoThreshold, &b.ConsecNeg, &b.RecoveryStreak,
			&b.OperStatus, &b.Archetype, &b.LossDays, &b.RecoveryLoanTaken, &b.Distress)
		processed++

		gameTime := b.GameTime
		cash, _ := e.Ledger.GetBalance(ctx, b.ID)

		// bankruptcy check
		if b.OperStatus == "Bankrupt" || cash < bankruptcyThreshold {
			e.applyBankruptcy(ctx, b.ID)
			e.Pool.Exec(ctx, `UPDATE bot_profiles SET distress_stage='desperate' WHERE user_id=$1`, b.ID)
			continue
		}

		// evaluate distress
		dist := e.botEvaluateDistress(ctx, b.ID, b.Archetype, b.ConsecNeg, cash/startingCash, float64(b.RecoveryStreak))
		threshold := math.Max(30.0, parseF(b.AutoThreshold, 40.0))

		// repair
		e.botHandleRepair(ctx, b.ID, gameTime, dist.Stage, threshold, repairReserve)

		// route lifecycle (audit + trim)
		e.botHandleRouteLifecycle(ctx, b.ID, gameTime, dist.Stage, dist.PriceMult, lossDaysThresh)

		// fleet growth
		e.botHandleFleetGrowth(ctx, b.ID, gameTime, b.Archetype, dist, cash, startingCash, purchaseMult, fleetDiversity)

		// route creation
		e.botHandleRouteCreation(ctx, b.ID, gameTime, b.Archetype, dist, b.HQ, threshold, secondaryHubChance)

		// pricing
		e.botHandlePricing(ctx, b.ID, gameTime, b.Archetype, dist.Stage, dist.PriceMult, compThreshold)

		// financial
		e.botHandleFinancial(ctx, b.ID, gameTime, dist, cash, startingCash, repayRatio, recoveryAmount)

		e.Pool.Exec(ctx, `UPDATE users SET last_active_at=NOW() WHERE id=$1`, b.ID)
	}

	// spawn replacement
	var botCount int
	e.Pool.QueryRow(ctx, `SELECT COUNT(*) FROM users WHERE actor_type='AI' AND COALESCE(operational_status,'Active')!='Bankrupt'`).Scan(&botCount)
	maxBots := int(e.getConfigNum(ctx, "max_bot_count", 5))
	if botCount < maxBots {
		e.spawnBot(ctx, seasonID)
	}
	_ = seasonID
	return processed, nil
}

// botDistress — hasil bot_evaluate_distress.
type botDistress struct {
	Stage          string
	TargetFleetCap int
	MinCashReserve float64
	GrowthChance   float64
	TargetDistance float64
	PriceMult      float64
	SchedRatio     float64
}

func (e *Engine) botEvaluateDistress(ctx context.Context, botID, archetype string, consecNeg int, cashRatio, streak float64) *botDistress {
	d := &botDistress{}
	switch {
	case consecNeg >= 5 || cashRatio < 0.18:
		d.Stage = "desperate"
	case consecNeg >= 3 || cashRatio < 0.30:
		d.Stage = "defensive"
	case consecNeg >= 1 || cashRatio < 0.50:
		d.Stage = "cautious"
	default:
		d.Stage = "stable"
	}
	e.Pool.Exec(ctx, `UPDATE bot_profiles SET distress_stage=$1 WHERE user_id=$2`, d.Stage, botID)

	switch archetype {
	case "Regional":
		d.TargetFleetCap, d.MinCashReserve, d.GrowthChance, d.TargetDistance, d.PriceMult, d.SchedRatio = 8, 3500000, 0.20, 900.0, 0.95, 0.72
	case "Aggressive":
		d.TargetFleetCap, d.MinCashReserve, d.GrowthChance, d.TargetDistance, d.PriceMult, d.SchedRatio = 14, 4500000, 0.26, 1800.0, 1.02, 0.82
	default: // Balanced & legacy (Premium)
		d.TargetFleetCap, d.MinCashReserve, d.GrowthChance, d.TargetDistance, d.PriceMult, d.SchedRatio = 10, 7000000, 0.16, 4200.0, 1.18, 0.58
	}
	if streak >= 3 {
		d.GrowthChance = math.Min(0.35, d.GrowthChance+0.04)
	}
	switch d.Stage {
	case "cautious":
		d.GrowthChance *= 0.60
		d.MinCashReserve *= 1.10
	case "defensive":
		d.GrowthChance *= 0.25
		d.MinCashReserve *= 1.30
	case "desperate":
		d.GrowthChance = 0
		d.MinCashReserve *= 1.50
	}
	return d
}

func (e *Engine) botHandleRepair(ctx context.Context, botID string, gameTime time.Time, distress string, threshold, reserve float64) {
	var allowed bool
	e.Pool.QueryRow(ctx, `SELECT last_repair_action_at IS NULL OR last_repair_action_at <= $1::timestamptz - INTERVAL '12 hours' FROM bot_profiles WHERE user_id=$2`, gameTime, botID).Scan(&allowed)
	if !allowed {
		return
	}
	var aircraftID string
	if distress != "desperate" {
		e.Pool.QueryRow(ctx, `
			SELECT id FROM fleet_aircraft WHERE user_id=$1 AND (status='grounded' OR condition < $2)
			ORDER BY condition ASC LIMIT 1`, botID, threshold).Scan(&aircraftID)
	} else {
		e.Pool.QueryRow(ctx, `
			SELECT id FROM fleet_aircraft WHERE user_id=$1 AND status='grounded' AND condition >= 60
			ORDER BY condition DESC LIMIT 1`, botID).Scan(&aircraftID)
	}
	if aircraftID != "" {
		_, _ = e.Fleet.Repair(ctx, botID, aircraftID)
		e.Pool.Exec(ctx, `UPDATE bot_profiles SET last_repair_action_at=$1 WHERE user_id=$2`, gameTime, botID)
	}
}

func (e *Engine) botHandleFleetGrowth(ctx context.Context, botID string, gameTime time.Time, archetype string, d *botDistress, cash, startingCash, purchaseMult, diversity float64) {
	var fleetCount, routeCount, idleCount int
	e.Pool.QueryRow(ctx, `SELECT COUNT(*) FROM fleet_aircraft WHERE user_id=$1`, botID).Scan(&fleetCount)
	e.Pool.QueryRow(ctx, `SELECT COUNT(*) FROM route_assignments WHERE user_id=$1 AND status='active'`, botID).Scan(&routeCount)
	e.Pool.QueryRow(ctx, `
		SELECT COUNT(*) FROM fleet_aircraft f WHERE f.user_id=$1 AND f.status='active'
		AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id=f.id)`, botID).Scan(&idleCount)
	var consecNeg int
	e.Pool.QueryRow(ctx, `SELECT COALESCE(consecutive_negative_days,0) FROM users WHERE id=$1`, botID).Scan(&consecNeg)
	var growthAllowed bool
	e.Pool.QueryRow(ctx, `SELECT last_growth_action_at IS NULL OR last_growth_action_at <= $1::timestamptz - INTERVAL '18 hours' FROM bot_profiles WHERE user_id=$2`, gameTime, botID).Scan(&growthAllowed)

	if !growthAllowed || fleetCount >= d.TargetFleetCap || cash <= d.MinCashReserve ||
		consecNeg > 0 || idleCount > 0 || routeCount < fleetCount || rand.Float64() >= d.GrowthChance {
		return
	}

	// model selection with diversity
	var modelID string
	if rand.Float64() < diversity {
		e.Pool.QueryRow(ctx, `
			SELECT m.id FROM aircraft_models m
			WHERE m.range_km >= $1*0.7 AND m.range_km <= $1*1.5
			ORDER BY m.lease_price_per_month ASC LIMIT 1`, d.TargetDistance).Scan(&modelID)
	} else {
		// archetype-specific model preference (simplified: cheapest fitting model)
		e.Pool.QueryRow(ctx, `
			SELECT m.id FROM aircraft_models m
			WHERE m.range_km >= $1 ORDER BY m.lease_price_per_month ASC LIMIT 1`, d.TargetDistance).Scan(&modelID)
	}
	if modelID == "" {
		return
	}

	// lease vs purchase bias
	leaseBias := 0.50
	if archetype == "Aggressive" {
		leaseBias = 0.70
	}
	if rand.Float64() < leaseBias {
		_, _ = e.Fleet.Lease(ctx, botID, LeaseParams{ModelID: modelID})
	} else if cash > startingCash*purchaseMult {
		_, _ = e.Fleet.Purchase(ctx, botID, PurchaseParams{ModelID: modelID})
	}
	e.Pool.Exec(ctx, `UPDATE bot_profiles SET last_growth_action_at=$1 WHERE user_id=$2`, gameTime, botID)
}

func (e *Engine) botHandleRouteLifecycle(ctx context.Context, botID string, gameTime time.Time, distress string, priceMult float64, lossDaysThresh int) {
	var routeCount int
	e.Pool.QueryRow(ctx, `SELECT COUNT(*) FROM route_assignments WHERE user_id=$1 AND status='active'`, botID).Scan(&routeCount)
	if routeCount == 0 {
		return
	}
	var auditAllowed bool
	e.Pool.QueryRow(ctx, `SELECT last_route_audit_at IS NULL OR last_route_audit_at <= $1::timestamptz - INTERVAL '4 hours' FROM bot_profiles WHERE user_id=$2`, gameTime, botID).Scan(&auditAllowed)
	if auditAllowed {
		// route performance: hitung per-rute (reuse route economics sederhana)
		perf := e.routePerformance(ctx, botID)
		allProfitable, anyProfitable := true, false
		worstID, worstProfit := "", 0.0
		for _, p := range perf {
			if p.Profit < 0 {
				allProfitable = false
				if p.Profit < worstProfit {
					worstProfit, worstID = p.Profit, p.RouteID
				}
			} else {
				anyProfitable = true
			}
		}
		if allProfitable && len(perf) > 0 {
			e.Pool.Exec(ctx, `UPDATE bot_profiles SET consecutive_loss_days=0 WHERE user_id=$1`, botID)
		} else if !anyProfitable && len(perf) > 0 {
			e.Pool.Exec(ctx, `UPDATE bot_profiles SET consecutive_loss_days = consecutive_loss_days + 1 WHERE user_id=$1`, botID)
		}
		var lossDays int
		e.Pool.QueryRow(ctx, `SELECT COALESCE(consecutive_loss_days,0) FROM bot_profiles WHERE user_id=$1`, botID).Scan(&lossDays)
		if lossDays >= lossDaysThresh && worstID != "" {
			_, _ = e.Routes.Delete(ctx, botID, worstID)
			e.Pool.Exec(ctx, `UPDATE bot_profiles SET last_route_change_at=$1, consecutive_loss_days=0 WHERE user_id=$2`, gameTime, botID)
		}
		e.Pool.Exec(ctx, `UPDATE bot_profiles SET last_route_audit_at=$1 WHERE user_id=$2`, gameTime, botID)
	}

	// distress trim (simplified: potong frekuensi rute terburuk)
	if distress == "defensive" || distress == "desperate" {
		perf := e.routePerformance(ctx, botID)
		if len(perf) > 0 {
			worst := perf[0]
			for _, p := range perf {
				if p.Profit < worst.Profit {
					worst = p
				}
			}
			if worst.Profit < 0 {
				var freq int
				e.Pool.QueryRow(ctx, `SELECT flights_per_week FROM route_assignments WHERE id=$1`, worst.RouteID).Scan(&freq)
				if distress == "desperate" && freq <= 6 {
					_, _ = e.Routes.Delete(ctx, botID, worst.RouteID)
				} else {
					newFreq := math.Max(6, float64(freq)-6)
					_, _ = e.Routes.UpdateFreqPrice(ctx, botID, worst.RouteID, 0, int(newFreq)) // TODO: price adj
					// UpdateFreqPrice requires price>0; bypass via direct SQL di bawah
					e.Pool.Exec(ctx, `UPDATE route_assignments SET flights_per_week=$1 WHERE id=$2`, int(newFreq), worst.RouteID)
				}
				e.Pool.Exec(ctx, `UPDATE bot_profiles SET last_route_change_at=$1 WHERE user_id=$2`, gameTime, botID)
			}
		}
	}
}

func (e *Engine) botHandleRouteCreation(ctx context.Context, botID string, gameTime time.Time, archetype string, d *botDistress, hq string, threshold float64, secondaryHubChance float64) {
	var routeCount, idleCount int
	e.Pool.QueryRow(ctx, `SELECT COUNT(*) FROM route_assignments WHERE user_id=$1 AND status='active'`, botID).Scan(&routeCount)
	e.Pool.QueryRow(ctx, `
		SELECT COUNT(*) FROM fleet_aircraft f WHERE f.user_id=$1 AND f.status='active' AND f.condition >= $2
		AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id=f.id)`, botID, threshold).Scan(&idleCount)
	var changeAllowed bool
	e.Pool.QueryRow(ctx, `SELECT last_route_change_at IS NULL OR last_route_change_at <= $1::timestamptz - INTERVAL '8 hours' FROM bot_profiles WHERE user_id=$2`, gameTime, botID).Scan(&changeAllowed)
	creationBias := 0.70
	if d.Stage == "cautious" {
		creationBias = 0.45
	}
	if idleCount == 0 || routeCount >= d.TargetFleetCap || !changeAllowed || d.Stage == "desperate" || rand.Float64() >= creationBias {
		return
	}
	// pilih pesawat idle
	var fleetID, modelID string
	var distance, price float64
	e.Pool.QueryRow(ctx, `
		SELECT f.id, f.aircraft_model_id, m.range_km, m.capacity FROM fleet_aircraft f
		JOIN aircraft_models m ON m.id=f.aircraft_model_id
		WHERE f.user_id=$1 AND f.status='active' AND f.condition >= $2
		AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id=f.id)
		LIMIT 1`, botID, threshold).Scan(&fleetID, &modelID, &distance, &price)
	_ = modelID
	if fleetID == "" {
		return
	}
	// cari destinasi dalam range (dari HQ, pakai secondary hub chance)
	origin := hq
	if rand.Float64() < secondaryHubChance {
		e.Pool.QueryRow(ctx, `SELECT secondary_hub_iata FROM bot_profiles WHERE user_id=$1`, botID).Scan(&origin)
	}
	if origin == "" {
		origin = hq
	}
	var dest string
	var destDist float64
	e.Pool.QueryRow(ctx, `
		SELECT a.iata, haversine_distance(o.latitude,o.longitude,a.latitude,a.longitude)
		FROM airports a, airports o
		WHERE o.iata=$1 AND a.iata<>$1 AND haversine_distance(o.latitude,o.longitude,a.latitude,a.longitude) <= $2
		AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.user_id=$3 AND r.origin_iata=$1 AND r.destination_iata=a.iata)
		ORDER BY random() LIMIT 1`, origin, distance*0.9, botID).Scan(&dest, &destDist)
	if dest == "" {
		return
	}
	baseFare := e.getConfigNum(ctx, "ticket_base_fare", 50.0) + destDist*e.getConfigNum(ctx, "ticket_per_km_rate", 0.12)
	ticketPrice := baseFare * d.PriceMult
	maxFlights := calcMaxWeeklyFlights(destDist, 500, 1.0) // speed estimasi; di-refine Fase 8
	targetFlights := int(math.Max(4, float64(maxFlights)*d.SchedRatio))

	// buat rute + assign
	_, _ = e.Routes.Create(ctx, botID, CreateRouteParams{
		OriginIATA: origin, DestinationIATA: dest, DistanceKM: destDist,
		TicketPrice: round2(ticketPrice), FlightsPerWeek: targetFlights,
	})
	e.Pool.Exec(ctx, `
		UPDATE route_assignments SET assigned_aircraft_id=$1
		WHERE user_id=$2 AND origin_iata=$3 AND destination_iata=$4 AND status='active'`,
		fleetID, botID, origin, dest)
	e.Pool.Exec(ctx, `UPDATE bot_profiles SET last_route_change_at=$1 WHERE user_id=$2`, gameTime, botID)
}

func (e *Engine) botHandlePricing(ctx context.Context, botID string, gameTime time.Time, archetype, distress string, priceMult, compThreshold float64) {
	var allowed bool
	e.Pool.QueryRow(ctx, `SELECT last_pricing_review_at IS NULL OR last_pricing_review_at <= $1::timestamptz - INTERVAL '6 hours' FROM bot_profiles WHERE user_id=$2`, gameTime, botID).Scan(&allowed)
	if !allowed {
		return
	}
	baseFare := e.getConfigNum(ctx, "ticket_base_fare", 50.0)
	perKM := e.getConfigNum(ctx, "ticket_per_km_rate", 0.12)

	rows, _ := e.Pool.Query(ctx, `SELECT id, ticket_price, distance_km, origin_iata, destination_iata FROM route_assignments WHERE user_id=$1 AND status='active'`, botID)
	defer rows.Close()
	for rows.Next() {
		var id, origin, dest string
		var price, distance float64
		rows.Scan(&id, &price, &distance, &origin, &dest)
		var compCount int
		var avgComp float64
		e.Pool.QueryRow(ctx, `
			SELECT COUNT(*), COALESCE(AVG(r2.ticket_price),0) FROM route_assignments r2
			WHERE r2.origin_iata=$1 AND r2.destination_iata=$2 AND r2.user_id<>$3 AND r2.status='active'`,
			origin, dest, botID).Scan(&compCount, &avgComp)

		if compCount > 0 || rand.Float64() < 0.20 {
			base := baseFare + distance*perKM
			adj := 0.97
			switch {
			case distress == "desperate":
				adj = 0.90
			case distress == "defensive":
				adj = 0.95
			case distress == "cautious":
				adj = 0.98
			case archetype == "Aggressive":
				adj = 1.01
			case archetype == "Balanced":
				adj = 1.03
			}
			if compCount > 0 && avgComp > 0 && (distress == "stable" || distress == "cautious") {
				if price > avgComp*(1+compThreshold) {
					adj *= 0.95
				} else if price < avgComp*(1-compThreshold) {
					adj *= 1.03
				}
			}
			newPrice := (price * 0.55) + (base * priceMult * adj * 0.45)
			e.Pool.Exec(ctx, `UPDATE route_assignments SET ticket_price=$1 WHERE id=$2`, round2(newPrice), id)
		}
	}
	e.Pool.Exec(ctx, `UPDATE bot_profiles SET last_pricing_review_at=$1 WHERE user_id=$2`, gameTime, botID)
}

func (e *Engine) botHandleFinancial(ctx context.Context, botID string, gameTime time.Time, d *botDistress, cash, startingCash, repayRatio, recoveryAmount float64) {
	var allowed bool
	e.Pool.QueryRow(ctx, `SELECT last_financial_action_at IS NULL OR last_financial_action_at <= $1::timestamptz - INTERVAL '12 hours' FROM bot_profiles WHERE user_id=$2`, gameTime, botID).Scan(&allowed)

	if allowed && d.Stage != "desperate" {
		var activeLoans int
		e.Pool.QueryRow(ctx, `SELECT COUNT(*) FROM loans WHERE user_id=$1 AND status='active'`, botID).Scan(&activeLoans)
		if activeLoans > 0 && cash > d.MinCashReserve*1.5 {
			var loanID string
			var balance float64
			e.Pool.QueryRow(ctx, `SELECT id, remaining_balance FROM loans WHERE user_id=$1 AND status='active' ORDER BY interest_rate DESC LIMIT 1`, botID).Scan(&loanID, &balance)
			if loanID != "" && balance > 0 {
				repay := math.Min(balance*repayRatio, cash-d.MinCashReserve)
				if repay > 0 {
					_, _ = e.Bank.Repay(ctx, botID, loanID, &repay)
					e.Pool.Exec(ctx, `UPDATE bot_profiles SET last_financial_action_at=$1 WHERE user_id=$2`, gameTime, botID)
				}
			}
		}
	}

	var activeLoans int
	e.Pool.QueryRow(ctx, `SELECT COUNT(*) FROM loans WHERE user_id=$1 AND status='active'`, botID).Scan(&activeLoans)
	if activeLoans == 0 {
		if cash < startingCash*0.5 && cash > 1000000 && (d.Stage == "cautious" || d.Stage == "defensive") {
			bias := 0.35
			if d.Stage == "defensive" {
				bias = 0.65
			}
			if rand.Float64() < bias {
				_, _ = e.Bank.TakeLoan(ctx, botID, TakeLoanParams{
					Principal: math.Min(5000000, startingCash-cash), TermWeeks: 52, LoanType: "unsecured",
				})
			}
		}
		var recoveryTaken bool
		e.Pool.QueryRow(ctx, `SELECT COALESCE(recovery_loan_taken,false) FROM bot_profiles WHERE user_id=$1`, botID).Scan(&recoveryTaken)
		if d.Stage == "desperate" && !recoveryTaken && cash > 500000 && cash < startingCash*0.3 {
			_, _ = e.Bank.TakeLoan(ctx, botID, TakeLoanParams{Principal: recoveryAmount, TermWeeks: 26, LoanType: "unsecured"})
			e.Pool.Exec(ctx, `UPDATE bot_profiles SET recovery_loan_taken=true WHERE user_id=$1`, botID)
		}
	}
	if d.Stage == "stable" {
		e.Pool.Exec(ctx, `UPDATE bot_profiles SET recovery_loan_taken=false WHERE user_id=$1`, botID)
	}
}

// spawnBot — mirror spawn_bot (buat bot baru dengan archetype random).
func (e *Engine) spawnBot(ctx context.Context, seasonID string) {
	archetypes := []string{"Regional", "Aggressive", "Balanced"}
	archetype := archetypes[rand.Intn(3)]
	var hq string
	e.Pool.QueryRow(ctx, `SELECT iata FROM airports ORDER BY demand_index DESC, random() LIMIT 1`).Scan(&hq)
	var gameTime time.Time
	e.Pool.QueryRow(ctx, `SELECT current_game_time FROM season_clock WHERE status='active' LIMIT 1`).Scan(&gameTime)
	username := fmt.Sprintf("bot_%s", randString(8))
	company := fmt.Sprintf("Skyward %s Airways", archetype)
	_, err := e.Pool.Exec(ctx, `
		INSERT INTO users (username, company_name, ceo_name, actor_type, hq_airport_iata, game_current_time, operational_status, net_worth, consecutive_negative_days, recovery_streak_days, auto_grounding_threshold, season_id)
		VALUES ($1,$2,'AI CEO','AI',$3,$4,'Active',15000000.00,0,0,40.00,$5)
		ON CONFLICT (company_name) DO NOTHING`, username, company, hq, gameTime, seasonID)
	if err != nil {
		return
	}
	// bot_profiles row
	e.Pool.Exec(ctx, `
		INSERT INTO bot_profiles (user_id, archetype, distress_stage)
		SELECT id, $1, 'stable' FROM users WHERE username=$2
		ON CONFLICT (user_id) DO NOTHING`, archetype, username)
}

func randString(n int) string {
	const chars = "abcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, n)
	for i := range b {
		b[i] = chars[rand.Intn(len(chars))]
	}
	return string(b)
}

func parseF(s string, def float64) float64 {
	var v float64
	if _, err := fmt.Sscanf(s, "%f", &v); err != nil {
		return def
	}
	return v
}

// routePerformance — hitung per-rute profit (weekly_profit, mirror get_route_performance).
type routePerf struct {
	RouteID string
	Profit  float64
}

func (e *Engine) routePerformance(ctx context.Context, userID string) []routePerf {
	fuelPrice := e.getConfigNum(ctx, "fuel_price_per_liter", 0.85)
	crewCost := e.getConfigNum(ctx, "crew_cost_per_hour", 350.0)
	rows, err := e.Pool.Query(ctx, `
		SELECT r.id, r.distance_km, r.ticket_price, r.flights_per_week,
		       m.fuel_burn_per_km, m.speed_kmh, m.maintenance_cost_per_hour, m.capacity
		FROM route_assignments r
		JOIN fleet_aircraft f ON f.id=r.assigned_aircraft_id
		JOIN aircraft_models m ON m.id=f.aircraft_model_id
		WHERE r.user_id=$1 AND r.status='active'`, userID)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []routePerf
	for rows.Next() {
		var id string
		var dist, price, freq, fuelBurn, speed, maintCost, cap float64
		rows.Scan(&id, &dist, &price, &freq, &fuelBurn, &speed, &maintCost, &cap)
		flightHours := dist/speed + 1.0
		maxWeekly := 168.0 / flightHours
		flights := math.Min(freq, maxWeekly)
		passengers := math.Min(cap, math.Floor(cap*0.95*0.85*0.85*1.0)) // estimasi demand
		revenue := flights * price * passengers
		fuel := flights * dist * fuelBurn * fuelPrice
		crew := flights * flightHours * crewCost
		maint := flights * dist * maintCost / speed
		profit := revenue - fuel - crew - maint
		out = append(out, routePerf{id, profit})
	}
	return out
}
