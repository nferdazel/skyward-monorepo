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

// ProcessBots — orchestrator bot (mirror execute_bot_decisions +
// process_all_bots_simulation_to_time). targetTime is the season clock; bot
// decisions are gated on it and each bot is then advanced through the shared
// player simulation so bot economics match the player model by construction.
func (e *Engine) ProcessBots(ctx context.Context, targetTime time.Time) (int, error) {
	startingCash := e.getConfigNum(ctx, "starting_cash", 25000000.0)
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
		SELECT u.id, u.hq_airport_iata, u.auto_grounding_threshold,
		       COALESCE(bp.archetype,'Balanced'), bp.consecutive_loss_days, bp.recovery_loan_taken,
		       COALESCE(bp.distress_stage,'stable')
		FROM users u LEFT JOIN bot_profiles bp ON bp.user_id=u.id
		WHERE u.actor_type='AI' AND COALESCE(u.operational_status,'Active') != 'Bankrupt'
		  AND (u.season_id IS NULL OR $1::uuid IS NULL OR u.season_id = $1)`, nullableSeason(seasonID))
	if err != nil {
		return 0, err
	}
	defer rows.Close()

	type botRow struct {
		ID                string
		HQ, AutoThreshold string
		Archetype         string
		LossDays          int
		RecoveryLoanTaken bool
		Distress          string
	}
	bots := []botRow{}
	for rows.Next() {
		var b botRow
		rows.Scan(&b.ID, &b.HQ, &b.AutoThreshold,
			&b.Archetype, &b.LossDays, &b.RecoveryLoanTaken, &b.Distress)
		bots = append(bots, b)
	}
	rows.Close()

	// Pass 1 — simulate every bot's economics forward to the season time,
	// matching process_all_bots_simulation_to_time. This posts route
	// revenue/costs, applies wear, runs the day boundary (loans, credit,
	// bankruptcy counters) and advances the bot clock. Doing all simulations
	// before any decisions keeps same-tick pricing/route effects from feeding
	// back into another bot's revenue within the same tick.
	for _, b := range bots {
		e.ProcessPlayer(ctx, b.ID, targetTime)
	}

	// Pass 2 — bot decisions (execute_bot_decisions), gated on the season time.
	processed := 0
	for _, b := range bots {
		gameTime := targetTime

		// Re-read state after the economic pass: cash, counters and status may
		// all have changed. Bots that went bankrupt are skipped and reaped.
		var operStatus string
		var consecNeg, recoveryStreak int
		e.Pool.QueryRow(ctx, `SELECT COALESCE(operational_status,'Active'), COALESCE(consecutive_negative_days,0), COALESCE(recovery_streak_days,0) FROM users WHERE id=$1`, b.ID).Scan(&operStatus, &consecNeg, &recoveryStreak)
		cash, _ := e.Ledger.GetBalance(ctx, b.ID)
		if operStatus == "Bankrupt" || cash < bankruptcyThreshold {
			e.applyBankruptcy(ctx, b.ID)
			e.Pool.Exec(ctx, `UPDATE bot_profiles SET distress_stage='desperate' WHERE user_id=$1`, b.ID)
			continue
		}
		processed++

		// evaluate distress
		dist := e.botEvaluateDistress(ctx, b.ID, b.Archetype, consecNeg, cash/startingCash, float64(recoveryStreak))
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
	}

	// Reap bankrupt bots so they do not accumulate (they were never counted
	// against max_bot_count, which previously let the AI population grow
	// unbounded). Use the same purge path as account deletion minus auth.
	e.reapBankruptBots(ctx)

	// Ensure the active bot population is exactly max_bot_count. Spawn one per
	// tick until the cap is reached so the world does not pop a full roster in
	// a single tick.
	maxBots := int(e.getConfigNum(ctx, "max_bot_count", 5))
	var botCount int
	e.Pool.QueryRow(ctx, `SELECT COUNT(*) FROM users WHERE actor_type='AI' AND COALESCE(operational_status,'Active') != 'Bankrupt' AND (season_id IS NULL OR $1::uuid IS NULL OR season_id = $1)`, nullableSeason(seasonID)).Scan(&botCount)
	if botCount < maxBots {
		e.spawnBot(ctx, seasonID)
	}
	return processed, nil
}

// nullableSeason passes nil for an empty season id so the `:uuid IS NULL`
// guards in bot queries match all seasons, mirroring the SQL reference.
func nullableSeason(seasonID string) *string {
	if seasonID == "" {
		return nil
	}
	return &seasonID
}

// reapBankruptBots removes AI users marked Bankrupt along with their dependent
// rows, so the bot population cannot grow without bound. Mirrors the DELETE
// ordering used by settings.DeleteAccount for the AI actor.
func (e *Engine) reapBankruptBots(ctx context.Context) {
	rows, err := e.Pool.Query(ctx, `SELECT id FROM users WHERE actor_type='AI' AND operational_status='Bankrupt'`)
	if err != nil {
		return
	}
	ids := []string{}
	for rows.Next() {
		var id string
		rows.Scan(&id)
		ids = append(ids, id)
	}
	rows.Close()
	for _, id := range ids {
		tx, txErr := e.Pool.Begin(ctx)
		if txErr != nil {
			continue
		}
		// Best-effort dependent cleanup: user-referencing FKs are ON DELETE
		// CASCADE, so the final DELETE would suffice. These explicit deletes are
		// defensive; a missing optional table must not abort the reap, so their
		// errors are ignored (the CASCADE covers correctness).
		for _, q := range []string{
			`DELETE FROM finance_snapshots WHERE user_id=$1`,
			`DELETE FROM bank_transactions WHERE user_id=$1`,
			`DELETE FROM bank_accounts WHERE user_id=$1`,
			`DELETE FROM achievements WHERE user_id=$1`,
			`DELETE FROM credit_score_history WHERE user_id=$1`,
			`DELETE FROM credit_scores WHERE user_id=$1`,
			`DELETE FROM route_assignments WHERE user_id=$1`,
			`DELETE FROM loans WHERE user_id=$1`,
			`DELETE FROM fleet_aircraft WHERE user_id=$1`,
		} {
			_, _ = tx.Exec(ctx, q, id)
		}
		if _, err := tx.Exec(ctx, `DELETE FROM bot_profiles WHERE user_id=$1`, id); err != nil {
			_ = tx.Rollback(ctx)
			continue
		}
		if _, err := tx.Exec(ctx, `DELETE FROM users WHERE id=$1`, id); err != nil {
			_ = tx.Rollback(ctx)
			continue
		}
		_ = tx.Commit(ctx)
	}
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
					_, _ = e.Routes.UpdateFreqPrice(ctx, botID, worst.RouteID, 0, int(newFreq))
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
	var modelSpeed, modelTurnaround float64
	e.Pool.QueryRow(ctx, `
		SELECT f.id, f.aircraft_model_id, m.range_km, m.capacity,
		       COALESCE(m.speed_kmh, 500), COALESCE(m.turnaround_hours, 1.0)
		FROM fleet_aircraft f
		JOIN aircraft_models m ON m.id=f.aircraft_model_id
		WHERE f.user_id=$1 AND f.status='active' AND f.condition >= $2
		AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id=f.id)
		LIMIT 1`, botID, threshold).Scan(&fleetID, &modelID, &distance, &price, &modelSpeed, &modelTurnaround)
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
	maxFlights := calcMaxWeeklyFlights(destDist, int(modelSpeed), modelTurnaround)
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

// botRespondPrice — pure pricing decision for one bot route review (GAME-22).
// Blends the archetype/distress target fare with a decisive response to a
// cheaper competitor, so bots converge toward the market within 1-2 reviews.
func botRespondPrice(price, base, avgComp float64, compCount int, priceMult,
	compThreshold float64, archetype, distress string) float64 {
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
	newPrice := (price * 0.55) + (base * priceMult * adj * 0.45)
	if compCount > 0 && avgComp > 0 {
		switch {
		case price > avgComp*(1+compThreshold):
			// Undercut: undercut back, but never below the marginal base fare.
			// Move 65% of the way toward the target so the bot converges within
			// 1-2 reviews rather than drifting ~2% per cycle.
			target := math.Max(avgComp*0.98, base*0.9)
			newPrice = (price * 0.35) + (target * 0.65)
		case price < avgComp*(1-compThreshold):
			// We are the cheapest by a wide margin; raise toward (not past) the
			// competitor.
			target := avgComp * 0.99
			newPrice = (price * 0.70) + (target * 0.30)
		}
	}
	return newPrice
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
			newPrice := botRespondPrice(price, base, avgComp, compCount, priceMult,
				compThreshold, archetype, distress)
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
// Company names are randomized (mirror generate_company_name) and the insert is
// retried on unique-violation, because users.company_name is UNIQUE. Without
// this the AI population could never exceed the number of distinct names.
func (e *Engine) spawnBot(ctx context.Context, seasonID string) {
	archetypes := []string{"Regional", "Aggressive", "Balanced"}
	archetype := archetypes[rand.Intn(3)]
	var hq string
	e.Pool.QueryRow(ctx, `SELECT iata FROM airports ORDER BY demand_index DESC, random() LIMIT 1`).Scan(&hq)
	var gameTime time.Time
	e.Pool.QueryRow(ctx, `SELECT current_game_time FROM season_clock WHERE status='active' LIMIT 1`).Scan(&gameTime)
	startingCash := e.getConfigNum(ctx, "starting_cash", 25000000.0)

	for attempt := 0; attempt < 10; attempt++ {
		username := fmt.Sprintf("bot_%s", randString(8))
		company := generateCompanyName(archetype)
		var id string
		err := e.Pool.QueryRow(ctx, `
			INSERT INTO users (username, company_name, ceo_name, actor_type, hq_airport_iata, game_current_time, operational_status, net_worth, consecutive_negative_days, recovery_streak_days, auto_grounding_threshold, season_id)
			VALUES ($1,$2,'AI CEO','AI',$3,$4,'Active',$5,0,0,40.00,$6)
			RETURNING id`, username, company, hq, gameTime, startingCash, seasonID).Scan(&id)
		if err != nil {
			// Likely a company_name/username unique collision — retry with new
			// random values. Any other error will simply fail all attempts.
			continue
		}
		e.Pool.Exec(ctx, `
			INSERT INTO bot_profiles (user_id, archetype, distress_stage)
			VALUES ($1, $2, 'stable')
			ON CONFLICT (user_id) DO NOTHING`, id, archetype)
		return
	}
}

// generateCompanyName mirrors generate_company_name(archetype).
func generateCompanyName(archetype string) string {
	prefixes := []string{"Pacific", "Atlas", "Eagle", "Nova", "Apex", "Summit", "Horizon", "Zenith",
		"Sterling", "Phoenix", "Titan", "Vanguard", "Sovereign", "Pinnacle", "Crest",
		"Falcon", "Meridian", "Aurora", "Comet", "Star", "Sky", "Air", "Jet", "Swift"}
	suffixes := []string{"Airways", "Air", "Airlines", "Aviation", "Air Lines", "Express", "Air Services"}
	regional := []string{"Regional", "Air Express", "Commuter", "Air Link", "Connect"}
	premium := []string{"International", "World", "Global", "Airways International", "Premium"}

	name := prefixes[rand.Intn(len(prefixes))]
	switch archetype {
	case "Regional":
		name += " " + regional[rand.Intn(len(regional))]
	case "Aggressive":
		name += " " + suffixes[rand.Intn(len(suffixes))]
	case "Balanced":
		name += " " + premium[rand.Intn(len(premium))]
	default:
		name += " " + suffixes[rand.Intn(len(suffixes))]
	}
	return name
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

// routePerformance — weekly profit per active route for a bot. Uses the same
// demand-pool + cabin-allocation model as the player simulation (GAME-25);
// the legacy SQL get_route_performance is deprecated and unused.
type routePerf struct {
	RouteID string
	Profit  float64
}

// routePerfParams — input untuk perhitungan ekonomi satu rute bot.
type routePerfParams struct {
	DistanceKM, TicketPrice, FlightsPerWeek        float64
	FuelBurnPerKM, SpeedKMH, MaintCostHr, Capacity float64
	TurnaroundHours                                float64
	OriginDemand, DestDemand                       int
	EconomySeats, BusinessSeats, FirstClassSeats   int
	AcqType                                        string
	LeasePriceMonth                                float64
}

// routePerfConfig — parameter ekonomi global (game_config).
type routePerfConfig struct {
	FuelPrice, CrewCost, TicketBase, TicketKM, MaxWeekly, DemandPoolScale float64
	BusinessFareMult, FirstFareMult                                       float64
	EconomyWilling, BusinessWilling, FirstWilling                         float64
	CargoPct                                                              float64
}

// routeWeeklyProfit — pure per-route weekly profit estimate for bots. Shares
// routeDailyDemand + allocateCabins with ProcessPlayer (GAME-25). Unlike the
// player tick it excludes event multipliers (bots have no target time) but does
// include cargo revenue and lease cost so the sign matches the player's model.
func routeWeeklyProfit(p routePerfParams, c routePerfConfig) float64 {
	flightHours := p.DistanceKM/p.SpeedKMH + p.TurnaroundHours
	if flightHours <= 0 {
		return 0
	}
	vMaxWeekly := c.MaxWeekly / flightHours
	flights := math.Min(p.FlightsPerWeek, vMaxWeekly)

	econSeats, bizSeats, firstSeats := p.EconomySeats, p.BusinessSeats, p.FirstClassSeats
	if econSeats+bizSeats+firstSeats <= 0 {
		econSeats = int(math.Floor(p.Capacity))
		bizSeats, firstSeats = 0, 0
	}
	dailyDemand := routeDailyDemand(p.OriginDemand, p.DestDemand, p.DistanceKM,
		p.TicketPrice, c.TicketBase, c.TicketKM, c.DemandPoolScale)
	flightsPerDay := flights / 7.0
	allocation := allocateCabins(
		int(math.Round(float64(econSeats)*flightsPerDay)),
		int(math.Round(float64(bizSeats)*flightsPerDay)),
		int(math.Round(float64(firstSeats)*flightsPerDay)),
		p.TicketPrice, c.BusinessFareMult, c.FirstFareMult,
		c.EconomyWilling, c.BusinessWilling, c.FirstWilling,
		dailyDemand, 1.0,
	)
	revenue := allocation.Revenue * 7.0
	revenue += revenue * c.CargoPct
	fuel := flights * p.DistanceKM * p.FuelBurnPerKM * c.FuelPrice
	crew := flights * flightHours * crewCostFor(c.CrewCost, p.Capacity)
	maint := flights * p.DistanceKM * p.MaintCostHr / p.SpeedKMH
	lease := 0.0
	if p.AcqType == "lease" {
		// ProcessPlayer uses lease_price_per_month * (elapsed/30); the weekly
		// run-rate equivalent is the monthly price over ~4.345 weeks.
		lease = p.LeasePriceMonth * 7.0 / 30.0
	}
	return revenue - fuel - crew - maint - lease
}

func (e *Engine) routePerformance(ctx context.Context, userID string) []routePerf {
	cfg := routePerfConfig{
		FuelPrice:        e.getConfigNum(ctx, "fuel_price_per_liter", 0.85),
		CrewCost:         e.getConfigNum(ctx, "crew_cost_per_hour", 350.0),
		TicketBase:       e.getConfigNum(ctx, "ticket_base_fare", 50.0),
		TicketKM:         e.getConfigNum(ctx, "ticket_per_km_rate", 0.12),
		MaxWeekly:        e.getConfigNum(ctx, "max_weekly_flights", 168.0),
		DemandPoolScale:  e.getConfigNum(ctx, "demand_pool_scale", 290.0),
		BusinessFareMult: e.getConfigNum(ctx, "business_fare_multiplier", 1.5),
		FirstFareMult:    e.getConfigNum(ctx, "first_fare_multiplier", 2.5),
		EconomyWilling:   e.getConfigNum(ctx, "economy_willing_share", 0.80),
		BusinessWilling:  e.getConfigNum(ctx, "business_willing_share", 0.15),
		FirstWilling:     e.getConfigNum(ctx, "first_willing_share", 0.05),
		CargoPct:         e.getConfigNum(ctx, "cargo_revenue_percentage", 0.05),
	}
	rows, err := e.Pool.Query(ctx, `
		SELECT r.id, r.distance_km, r.ticket_price, r.flights_per_week,
		       m.fuel_burn_per_km, m.speed_kmh, m.maintenance_cost_per_hour, m.capacity,
		       a1.demand_index, a2.demand_index,
		       COALESCE(f.economy_seats, 0), COALESCE(f.business_seats, 0), COALESCE(f.first_class_seats, 0),
		       COALESCE(f.acquisition_type, 'owned'), COALESCE(m.lease_price_per_month, 0),
		       COALESCE(m.turnaround_hours, 1.0)
		FROM route_assignments r
		JOIN fleet_aircraft f ON f.id=r.assigned_aircraft_id
		JOIN aircraft_models m ON m.id=f.aircraft_model_id
		JOIN airports a1 ON a1.iata=r.origin_iata
		JOIN airports a2 ON a2.iata=r.destination_iata
		WHERE r.user_id=$1 AND r.status='active' AND f.status='active'`, userID)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []routePerf
	for rows.Next() {
		var id string
		var p routePerfParams
		rows.Scan(&id, &p.DistanceKM, &p.TicketPrice, &p.FlightsPerWeek,
			&p.FuelBurnPerKM, &p.SpeedKMH, &p.MaintCostHr, &p.Capacity,
			&p.OriginDemand, &p.DestDemand, &p.EconomySeats, &p.BusinessSeats, &p.FirstClassSeats,
			&p.AcqType, &p.LeasePriceMonth, &p.TurnaroundHours)
		out = append(out, routePerf{id, routeWeeklyProfit(p, cfg)})
	}
	return out
}
