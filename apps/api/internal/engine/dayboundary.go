// Package engine — day-boundary & events helpers (Fase 6, Go-native).
// Port dari: generate_game_events, deactivate_expired_events, process_loan_payments,
// process_aircraft_financing_payments, process_credit_at_day_boundary (+calculate_credit_score).
package engine

import (
	"context"
	"fmt"
	"math"
	"math/rand"
	"time"
)

// ── Events ────────────────────────────────────────────────────────────

// GenerateGameEvents — 5% chance per tick, mirror generate_game_events.
func (e *Engine) GenerateGameEvents(ctx context.Context, gameTime time.Time) {
	if rand.Float64() > 0.05 {
		return
	}
	var (
		eventType, effectType, effectTarget, title, desc string
		effectValue                                      float64
	)
	switch rand.Intn(4) {
	case 0: // fuel_shock global
		eventType, effectType, effectTarget = "fuel_shock", "fuel_price", "global"
		effectValue = 0.7 + rand.Float64()*0.6
		if effectValue > 1.0 {
			title = "Fuel Price Surge"
			desc = fmt.Sprintf("Global fuel prices have increased by %.0f%%", (effectValue-1)*100)
		} else {
			title = "Fuel Price Drop"
			desc = fmt.Sprintf("Global fuel prices have decreased by %.0f%%", (1-effectValue)*100)
		}
	case 1: // demand_surge random airport
		var iata string
		e.Pool.QueryRow(ctx, `SELECT iata FROM airports ORDER BY random() LIMIT 1`).Scan(&iata)
		if iata == "" {
			return
		}
		eventType, effectType, effectTarget = "demand_surge", "demand_index", iata
		effectValue = 1.2 + rand.Float64()*0.3
		title = "Demand Surge at " + iata
		desc = fmt.Sprintf("Increased passenger demand at %s airport", iata)
	case 2: // weather_disruption high-demand airport
		var iata string
		e.Pool.QueryRow(ctx, `SELECT iata FROM airports WHERE demand_index > 70 ORDER BY random() LIMIT 1`).Scan(&iata)
		if iata == "" {
			e.Pool.QueryRow(ctx, `SELECT iata FROM airports ORDER BY random() LIMIT 1`).Scan(&iata)
		}
		if iata == "" {
			return
		}
		eventType, effectType, effectTarget = "weather_disruption", "demand_index", iata
		effectValue = 0.5
		title = "Weather Disruption at " + iata
		desc = fmt.Sprintf("Severe weather affecting operations at %s", iata)
	default: // maintenance_shock global
		eventType, effectType, effectTarget = "maintenance_shock", "maintenance_cost", "global"
		effectValue = 1.10 + rand.Float64()*0.20
		title = "Maintenance Cost Surge"
		desc = fmt.Sprintf("Maintenance costs increased by %.0f%% globally", (effectValue-1)*100)
	}

	// skip jika event serupa sudah aktif
	var exists bool
	e.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM game_events WHERE event_type=$1 AND is_active=true AND effect_target=$2 AND end_game_time>$3)`,
		eventType, effectTarget, gameTime).Scan(&exists)
	if exists {
		return
	}
	e.Pool.Exec(ctx, `INSERT INTO game_events (event_type, title, description, effect_type, effect_target, effect_value, start_game_time, end_game_time, is_active)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,true)`,
		eventType, title, desc, effectType, effectTarget, effectValue, gameTime, gameTime.Add(72*time.Hour))
}

// DeactivateExpiredEvents — mirror deactivate_expired_events.
func (e *Engine) DeactivateExpiredEvents(ctx context.Context, gameTime time.Time) {
	e.Pool.Exec(ctx, `UPDATE game_events SET is_active=false WHERE is_active=true AND end_game_time<=$1`, gameTime)
}

// ── Day boundary: loan payments ───────────────────────────────────────

// ProcessLoanPayments — mirror process_loan_payments (non-financing loans).
func (e *Engine) ProcessLoanPayments(ctx context.Context, userID string, gameDate time.Time) {
	var actorType string
	e.Pool.QueryRow(ctx, `SELECT actor_type FROM users WHERE id=$1`, userID).Scan(&actorType)
	if actorType == "" {
		return
	}
	cash, _ := e.Ledger.GetBalance(ctx, userID)

	type loanRow struct {
		ID               string
		WeeklyPayment    float64
		MonthlyPayment   float64
		RemainingBalance float64
		Collateral       *string
	}
	rows, err := e.Pool.Query(ctx, `
		SELECT id, weekly_payment, monthly_payment, remaining_balance, collateral_aircraft_id
		FROM loans WHERE user_id=$1 AND status='active' AND loan_type != 'aircraft_financing'
		ORDER BY taken_at ASC`, userID)
	if err != nil {
		return
	}
	defer rows.Close()
	for rows.Next() {
		var l loanRow
		rows.Scan(&l.ID, &l.WeeklyPayment, &l.MonthlyPayment, &l.RemainingBalance, &l.Collateral)
		payment := l.WeeklyPayment
		if payment <= 0 && l.MonthlyPayment > 0 {
			payment = l.MonthlyPayment / 4.33
		}
		if payment <= 0 {
			continue
		}
		if cash >= payment {
			tx, txErr := e.Pool.Begin(ctx)
			if txErr == nil {
				_, dErr := e.Ledger.DebitTx(ctx, tx, userID, payment, "financing", "loan_payment", "Weekly loan payment", gameDate)
				if dErr == nil {
					_, _ = tx.Exec(ctx, `
						UPDATE loans SET remaining_balance = GREATEST(0, remaining_balance - $1),
						       status = CASE WHEN remaining_balance - $1 <= 0.005 THEN 'paid_off'::varchar ELSE status END
						WHERE id=$2`, payment, l.ID)
					if tx.Commit(ctx) == nil {
						cash -= payment
					} else {
						tx.Rollback(ctx) //nolint:errcheck
					}
				} else {
					tx.Rollback(ctx) //nolint:errcheck
				}
			}
		} else {
			lateFee := payment * 0.10
			e.Pool.Exec(ctx, `UPDATE loans SET remaining_balance = remaining_balance + $1, missed_payments = missed_payments + 1 WHERE id=$2`, lateFee, l.ID)
			var missed int
			e.Pool.QueryRow(ctx, `SELECT missed_payments FROM loans WHERE id=$1`, l.ID).Scan(&missed)
			if missed >= 4 {
				e.Pool.Exec(ctx, `UPDATE loans SET status='defaulted' WHERE id=$1`, l.ID)
				if l.Collateral != nil {
					e.Pool.Exec(ctx, `UPDATE fleet_aircraft SET status='grounded' WHERE id=$1`, *l.Collateral)
				}
			}
		}
	}
}

// ProcessAircraftFinancingPayments — mirror process_aircraft_financing_payments.
func (e *Engine) ProcessAircraftFinancingPayments(ctx context.Context, userID string, gameDate time.Time) {
	cash, _ := e.Ledger.GetBalance(ctx, userID)
	type finRow struct {
		ID               string
		WeeklyPayment    float64
		MonthlyPayment   float64
		RemainingBalance float64
		Collateral       *string
	}
	rows, err := e.Pool.Query(ctx, `
		SELECT id, weekly_payment, monthly_payment, remaining_balance, collateral_aircraft_id
		FROM loans WHERE user_id=$1 AND loan_type='aircraft_financing' AND status='active'`, userID)
	if err != nil {
		return
	}
	defer rows.Close()
	for rows.Next() {
		var l finRow
		rows.Scan(&l.ID, &l.WeeklyPayment, &l.MonthlyPayment, &l.RemainingBalance, &l.Collateral)
		payment := l.WeeklyPayment
		if payment <= 0 && l.MonthlyPayment > 0 {
			payment = l.MonthlyPayment / 4.33
		}
		if payment <= 0 {
			continue
		}
		if cash >= payment {
			tx, txErr := e.Pool.Begin(ctx)
			if txErr == nil {
				_, dErr := e.Ledger.DebitTx(ctx, tx, userID, payment, "financing", "financing_payment", "Aircraft financing payment", gameDate)
				if dErr == nil {
					_, _ = tx.Exec(ctx, `
						UPDATE loans SET remaining_balance = GREATEST(0, remaining_balance - $1),
						       status = CASE WHEN remaining_balance - $1 <= 0.005 THEN 'paid_off'::varchar ELSE status END
						WHERE id=$2`, payment, l.ID)
					if tx.Commit(ctx) == nil {
						cash -= payment
					} else {
						tx.Rollback(ctx) //nolint:errcheck
					}
				} else {
					tx.Rollback(ctx) //nolint:errcheck
				}
			}
		} else {
			lateFee := payment * 0.05
			e.Pool.Exec(ctx, `UPDATE loans SET remaining_balance = remaining_balance + $1, missed_payments = missed_payments + 1 WHERE id=$2`, lateFee, l.ID)
			var missed int
			e.Pool.QueryRow(ctx, `SELECT missed_payments FROM loans WHERE id=$1`, l.ID).Scan(&missed)
			if missed >= 3 {
				e.Pool.Exec(ctx, `UPDATE loans SET status='repossessed' WHERE id=$1`, l.ID)
				if l.Collateral != nil {
					e.Pool.Exec(ctx, `UPDATE fleet_aircraft SET status='grounded' WHERE id=$1`, *l.Collateral)
				}
			}
		}
	}
}

// ── Day boundary: credit score ────────────────────────────────────────

// ProcessCreditAtDayBoundary — mirror process_credit_at_day_boundary + update_credit_score.
func (e *Engine) ProcessCreditAtDayBoundary(ctx context.Context, userID string, gameDate time.Time) {
	score, ok := e.calculateCreditScore(ctx, userID)
	if !ok {
		return
	}
	tier := resolveCreditTier(score.Total)
	e.Pool.Exec(ctx, `
		INSERT INTO credit_scores (user_id, score, tier, fleet_health_score, revenue_stability_score, debt_ratio_score, cash_reserves_score, profit_history_score, computed_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,NOW())
		ON CONFLICT (user_id) DO UPDATE SET score=EXCLUDED.score, tier=EXCLUDED.tier,
			fleet_health_score=EXCLUDED.fleet_health_score, revenue_stability_score=EXCLUDED.revenue_stability_score,
			debt_ratio_score=EXCLUDED.debt_ratio_score, cash_reserves_score=EXCLUDED.cash_reserves_score,
			profit_history_score=EXCLUDED.profit_history_score, computed_at=EXCLUDED.computed_at`,
		userID, score.Total, tier, score.FleetHealth, score.RevenueStability, score.DebtRatio, score.CashReserve, score.ProfitHistory)
	e.Pool.Exec(ctx, `
		INSERT INTO credit_score_history (user_id, game_date, score, tier, fleet_health_score, revenue_stability_score, debt_ratio_score, cash_reserves_score, profit_history_score)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
		ON CONFLICT (user_id, game_date) DO NOTHING`,
		userID, gameDate, score.Total, tier, score.FleetHealth, score.RevenueStability, score.DebtRatio, score.CashReserve, score.ProfitHistory)
}

type creditScore struct {
	Total            int
	FleetHealth      int
	RevenueStability int
	DebtRatio        int
	CashReserve      int
	ProfitHistory    int
}

// calculateCreditScore — mirror calculate_credit_score.
func (e *Engine) calculateCreditScore(ctx context.Context, userID string) (*creditScore, bool) {
	var netWorth float64
	var gameTime time.Time
	err := e.Pool.QueryRow(ctx, `SELECT net_worth, game_current_time FROM users WHERE id=$1`, userID).Scan(&netWorth, &gameTime)
	if err != nil {
		return &creditScore{500, 100, 100, 100, 100, 100}, true // fallback
	}
	cash, _ := e.Ledger.GetBalance(ctx, userID)
	startingCash := e.getConfigNum(ctx, "starting_cash", 15000000.0)

	var fleetCount int
	var avgCondition, groundedRatio float64
	e.Pool.QueryRow(ctx, `
		SELECT COUNT(*), COALESCE(AVG(condition),100.0),
		       COALESCE(COUNT(*) FILTER (WHERE status='grounded')::numeric / NULLIF(COUNT(*),0), 0.0)
		FROM fleet_aircraft WHERE user_id=$1`, userID).Scan(&fleetCount, &avgCondition, &groundedRatio)

	fleetHealth := 70.0
	if fleetCount > 0 {
		fleetHealth = math.Min(200.0, (avgCondition/100.0)*130.0+50.0*(1.0-groundedRatio)+math.Min(20.0, float64(fleetCount)*2.0))
	}

	// revenue stability (stddev of daily revenue, 30d)
	// NB: cutoff dihitung di Go ($2 = timestamptz) — menghindari `$2 - INTERVAL`
	// yang bikin Postgres men-infer `$2` sebagai interval → error tipe.
	cutoff := gameTime.AddDate(0, 0, -30)
	var revStddev, revAvg float64
	e.Pool.QueryRow(ctx, `
		SELECT COALESCE(STDDEV(daily_revenue),0), COALESCE(AVG(daily_revenue),0)
		FROM (SELECT SUM(amount) AS daily_revenue FROM bank_transactions
		      WHERE user_id=$1 AND ifrs_category='revenue' AND game_date >= $2
		      GROUP BY (game_date AT TIME ZONE 'UTC')::DATE) daily`, userID, cutoff).Scan(&revStddev, &revAvg)

	revenueStability := 60.0
	if revAvg > 0 {
		revenueStability = math.Max(0, math.Min(200.0, 170.0-revStddev/revAvg*100.0))
	}

	// 30d revenue/expense
	var totalRev30d, totalExp30d float64
	e.Pool.QueryRow(ctx, `
		SELECT COALESCE(SUM(CASE WHEN transaction_type='credit' THEN amount ELSE 0 END),0),
		       ABS(COALESCE(SUM(CASE WHEN transaction_type='debit' THEN amount ELSE 0 END),0))
		FROM bank_transactions WHERE user_id=$1 AND game_date >= $2 AND ifrs_category IN ('revenue','cogs','opex')`,
		userID, cutoff).Scan(&totalRev30d, &totalExp30d)

	// debt ratio
	var totalDebt float64
	e.Pool.QueryRow(ctx, `SELECT COALESCE(SUM(remaining_balance),0) FROM loans WHERE user_id=$1 AND status='active'`, userID).Scan(&totalDebt)
	debtRatio := 130.0
	switch {
	case totalDebt <= 0:
		if totalRev30d > 0 || fleetCount > 0 {
			debtRatio = 180.0
		} else {
			debtRatio = 130.0
		}
	case netWorth > 0:
		debtRatio = math.Max(0, 180.0-(totalDebt/netWorth)*180.0)
	default:
		debtRatio = 0.0
	}

	// cash reserve
	cashReserve := 80.0
	if startingCash > 0 {
		cashReserve = math.Max(0, math.Min(180.0, 60.0+(cash/startingCash)*60.0))
	}
	if totalRev30d <= 0 {
		cashReserve = math.Min(cashReserve, 130.0)
	}

	// profit history
	profitHistory := 60.0
	if totalRev30d > 0 {
		margin := (totalRev30d - totalExp30d) / totalRev30d
		profitHistory = math.Min(200.0, math.Max(20.0, 90.0+margin*140.0))
	}

	total := int(math.Max(0, math.Min(1000,
		math.Round(fleetHealth)+math.Round(revenueStability)+math.Round(debtRatio)+math.Round(cashReserve)+math.Round(profitHistory))))

	return &creditScore{
		Total:            total,
		FleetHealth:      int(math.Round(fleetHealth)),
		RevenueStability: int(math.Round(revenueStability)),
		DebtRatio:        int(math.Round(debtRatio)),
		CashReserve:      int(math.Round(cashReserve)),
		ProfitHistory:    int(math.Round(profitHistory)),
	}, true
}

// resolveCreditTier — mirror resolve_credit_tier (sesuai credit_tier_config).
func resolveCreditTier(score int) string {
	switch {
	case score >= 820:
		return "Platinum"
	case score >= 660:
		return "Gold"
	case score >= 520:
		return "Silver"
	default:
		return "Standard"
	}
}
