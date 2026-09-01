// Package engine — bank mutations (Fase 5), faithful ke fungsi SQL.
package engine

import (
	"context"
	"fmt"
)

// BankService — bank & credit mutations.
type BankService struct{ engine *Engine }

// TakeLoanParams — input take_loan.
type TakeLoanParams struct {
	Principal            float64 `json:"principal"`
	TermWeeks            int     `json:"term_weeks"`
	LoanType             string  `json:"loan_type"`
	CollateralAircraftID *string `json:"collateral_aircraft_id,omitempty"`
}

// TakeLoan — POST /bank/loans. Faithful port of take_loan(p_user_id,...).
func (b *BankService) TakeLoan(ctx context.Context, userID string, p TakeLoanParams) (*MutationResult, error) {
	// Validasi dasar + policy (credit tier config) — TODO Fase 6 lengkap.
	// Mirip take_loan: cek tier, limits, disbursement.
	if p.Principal <= 0 {
		return &MutationResult{Success: false, Message: "Loan amount must be positive."}, nil
	}
	if p.TermWeeks <= 0 {
		p.TermWeeks = 52
	}
	loanType := p.LoanType
	if loanType == "" {
		loanType = "unsecured"
	}
	// max_active_loans dari config
	var maxActive int
	b.engine.Pool.QueryRow(ctx, `SELECT COALESCE((value#>>'{max_active_loans}')::int, 3) FROM game_config WHERE key='credit_tier_config'`).Scan(&maxActive)
	var activeLoans int
	b.engine.Pool.QueryRow(ctx, `SELECT COUNT(*) FROM loans WHERE user_id=$1 AND status='active'`, userID).Scan(&activeLoans)
	if activeLoans >= maxActive {
		return &MutationResult{Success: false, Message: "Maximum active loans reached."}, nil
	}
	// rate dari tier policy — ambil unsecured rate Standard dulu (Fase 6 refine)
	var rate float64 = 0.12
	b.engine.Pool.QueryRow(ctx, `SELECT COALESCE((value#>>'{Standard,rate_unsecured}')::numeric, 0.12) FROM game_config WHERE key='credit_tier_config'`).Scan(&rate)

	// weekly payment (simple amortization, mirror take_loan)
	weekly := p.Principal * (1 + rate) / float64(p.TermWeeks)
	monthly := weekly * 4.33

	tx, err := b.engine.Pool.Begin(ctx)
	if err != nil {
		return &MutationResult{Success: false, Message: "transaction error"}, nil
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	gameTime, _ := b.engine.Ledger.GetUserGameTime(ctx, userID)
	var newCash float64
	var loanID string
	err = tx.QueryRow(ctx, `
		INSERT INTO loans (user_id, loan_type, principal, interest_rate, remaining_balance, weekly_payment, monthly_payment, status, term_months, originated_game_date)
		VALUES ($1,$2,$3,$4,$3,$5,$6,'active',CEIL($7/4.33)::int,$8)
		RETURNING id`,
		userID, loanType, p.Principal, rate, weekly, monthly, p.TermWeeks, gameTime).Scan(&loanID)
	if err != nil {
		return &MutationResult{Success: false, Message: "insert loan failed"}, nil
	}
	newCash, err = b.engine.Ledger.CreditTx(ctx, tx, userID, p.Principal, "financing", "loan_disbursement",
		fmt.Sprintf("Loan disbursement (%s)", loanType), gameTime)
	if err != nil {
		return &MutationResult{Success: false, Message: "disbursement failed"}, nil
	}
	tx.Commit(ctx) //nolint:errcheck
	return &MutationResult{Success: true, Message: "Loan approved and funds disbursed.", NewCash: newCash}, nil
}

// Repay — POST /bank/loans/{id}/repay. Faithful port of repay_loan.
func (b *BankService) Repay(ctx context.Context, userID, loanID string, amount *float64) (*MutationResult, error) {
	var remaining float64
	var loanType string
	var collateral *string
	err := b.engine.Pool.QueryRow(ctx,
		`SELECT remaining_balance, loan_type, collateral_aircraft_id FROM loans WHERE id=$1 AND user_id=$2 AND status='active'`,
		loanID, userID).Scan(&remaining, &loanType, &collateral)
	if err != nil {
		return &MutationResult{Success: false, Message: "Loan not found or already paid off."}, nil
	}
	payment := remaining
	if amount != nil {
		if *amount < remaining {
			payment = *amount
		}
	}
	if payment <= 0 {
		return &MutationResult{Success: false, Message: "Payment amount must be positive."}, nil
	}
	cash, _ := b.engine.Ledger.GetBalance(ctx, userID)
	if cash < payment {
		return &MutationResult{Success: false, Message: fmt.Sprintf("Insufficient cash. Need $%.2f, have $%.2f.", payment, cash), NewCash: cash}, nil
	}

	tx, err := b.engine.Pool.Begin(ctx)
	if err != nil {
		return &MutationResult{Success: false, Message: "transaction error", NewCash: cash}, nil
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	gameTime, _ := b.engine.Ledger.GetUserGameTime(ctx, userID)
	desc := "Loan partial repayment"
	paidOff := remaining-payment <= 0
	if paidOff {
		desc = "Loan fully repaid"
	}
	newCash, err := b.engine.Ledger.DebitTx(ctx, tx, userID, payment, "financing", "loan_repayment", desc, gameTime)
	if err != nil {
		return &MutationResult{Success: false, Message: "ledger debit failed", NewCash: cash}, nil
	}
	_, err = tx.Exec(ctx, `
		UPDATE loans SET remaining_balance = remaining_balance - $1,
		       status = CASE WHEN remaining_balance - $1 <= 0 THEN 'paid_off'::varchar ELSE status END
		WHERE id=$2`, payment, loanID)
	if err != nil {
		return &MutationResult{Success: false, Message: "update loan failed", NewCash: cash}, nil
	}
	// financed aircraft → owned saat lunas
	if paidOff && loanType == "aircraft_financing" && collateral != nil {
		tx.Exec(ctx, `UPDATE fleet_aircraft SET acquisition_type='purchase' WHERE id=$1 AND user_id=$2 AND acquisition_type='finance'`, *collateral, userID)
	}
	tx.Commit(ctx) //nolint:errcheck
	msg := "Payment applied."
	if paidOff {
		msg = "Loan fully repaid!"
	}
	return &MutationResult{Success: true, Message: msg, NewCash: newCash}, nil
}

// Refinance — POST /bank/loans/{id}/refinance. Faithful port of refinance_loan.
func (b *BankService) Refinance(ctx context.Context, userID, loanID string) (*MutationResult, error) {
	var loanType string
	var rate, remaining, weeklyPay, monthlyPay float64
	err := b.engine.Pool.QueryRow(ctx, `
		SELECT loan_type, interest_rate, remaining_balance, weekly_payment, monthly_payment
		FROM loans WHERE id=$1 AND user_id=$2 AND status='active'`, loanID, userID).
		Scan(&loanType, &rate, &remaining, &weeklyPay, &monthlyPay)
	if err != nil {
		return &MutationResult{false, "Loan not found or not active.", 0}, nil
	}
	// tier rate
	var tier string
	b.engine.Pool.QueryRow(ctx, `SELECT tier FROM credit_scores WHERE user_id=$1`, userID).Scan(&tier)
	if tier == "" {
		tier = "Standard"
	}
	var newRate float64
	if loanType == "secured" || loanType == "aircraft_financing" {
		newRate = b.tierRate(ctx, tier, "rate_secured", 0.06)
	} else {
		newRate = b.tierRate(ctx, tier, "rate_unsecured", 0.07)
	}
	if newRate >= rate {
		return &MutationResult{false, "Current rate is not better than existing rate.", 0}, nil
	}
	outstanding := remaining / (1 + rate)
	periods := 1.0
	if monthlyPay > 0 {
		periods = maxf(1, ceilDiv(remaining, monthlyPay))
	} else if weeklyPay > 0 {
		periods = maxf(1, ceilDiv(remaining, weeklyPay))
	}
	newTotal := outstanding * (1 + newRate)
	newMonthly := newTotal / periods
	newWeekly := newMonthly / 4.33
	_, err = b.engine.Pool.Exec(ctx, `
		UPDATE loans SET interest_rate=$1, remaining_balance=$2, weekly_payment=$3, monthly_payment=$4 WHERE id=$5`,
		newRate, newTotal, newWeekly, newMonthly, loanID)
	if err != nil {
		return &MutationResult{false, "refinance failed", 0}, nil
	}
	savings := maxf(0, remaining-newTotal)
	return &MutationResult{true, fmt.Sprintf("Loan refinanced successfully (savings $%.2f).", savings), 0}, nil
}

func (b *BankService) tierRate(ctx context.Context, tier, field string, fallback float64) float64 {
	var r float64
	err := b.engine.Pool.QueryRow(ctx,
		`SELECT COALESCE((value#>>$1)::numeric, $2) FROM game_config WHERE key='credit_tier_config'`,
		"{"+tier+","+field+"}", fallback).Scan(&r)
	if err != nil {
		return fallback
	}
	return r
}

func ceilDiv(a, b float64) float64 {
	c := a / b
	f := float64(int(c))
	if c > f {
		return f + 1
	}
	return f
}

// FinanceAircraftParams — input finance_aircraft.
type FinanceAircraftParams struct {
	ModelID        string  `json:"aircraft_model_id"`
	DownPaymentPct float64 `json:"down_payment_pct"`
	TermMonths     int     `json:"term_months"`
}

// FinanceAircraft — POST /bank/finance-aircraft. Faithful port of finance_aircraft.
func (b *BankService) FinanceAircraft(ctx context.Context, userID string, p FinanceAircraftParams) (*MutationResult, error) {
	var purchasePrice, capacity float64
	var modelName string
	err := b.engine.Pool.QueryRow(ctx, `SELECT purchase_price, capacity, model_name FROM aircraft_models WHERE id=$1`, p.ModelID).
		Scan(&purchasePrice, &capacity, &modelName)
	if err != nil {
		return &MutationResult{false, "Aircraft model not found.", 0}, nil
	}
	// tier
	var tier string
	b.engine.Pool.QueryRow(ctx, `SELECT tier FROM credit_scores WHERE user_id=$1`, userID).Scan(&tier)
	if tier == "" {
		tier = "Standard"
	}
	maxFinancing := b.tierRate(ctx, tier, "max_secured", 25000000)
	if purchasePrice > maxFinancing {
		return &MutationResult{false, fmt.Sprintf("Aircraft price ($%.0f) exceeds your financing limit ($%.0f) for tier %s.", purchasePrice, maxFinancing, tier), 0}, nil
	}
	if p.TermMonths == 0 {
		p.TermMonths = 36
	}
	if p.TermMonths != 12 && p.TermMonths != 24 && p.TermMonths != 36 && p.TermMonths != 48 && p.TermMonths != 60 {
		return &MutationResult{false, "Financing term must be 12, 24, 36, 48, or 60 months.", 0}, nil
	}
	if p.DownPaymentPct == 0 {
		p.DownPaymentPct = 0.20
	}
	if p.DownPaymentPct < 0.10 || p.DownPaymentPct > 0.50 {
		return &MutationResult{false, "Down payment must be between 10% and 50%.", 0}, nil
	}
	rate := b.tierRate(ctx, tier, "rate_secured", 0.10)
	down := round2(purchasePrice * p.DownPaymentPct)
	principal := purchasePrice - down
	totalRepayable := principal * (1 + rate)
	monthly := totalRepayable / float64(p.TermMonths)
	weekly := monthly / 4.33
	cash, _ := b.engine.Ledger.GetBalance(ctx, userID)
	if cash < down {
		return &MutationResult{false, fmt.Sprintf("Insufficient cash for down payment of $%.0f.", down), cash}, nil
	}
	var hq *string
	gameTime, err := b.engine.Ledger.GetUserGameTime(ctx, userID)
	if err != nil {
		return &MutationResult{false, "User not found.", 0}, nil
	}
	b.engine.Pool.QueryRow(ctx, `SELECT hq_airport_iata FROM users WHERE id=$1`, userID).Scan(&hq)
	tail, err := b.engine.Ledger.GenerateTailNumber(ctx, deref(hq, "CGK"))
	if err != nil {
		return &MutationResult{false, "tail number generation failed", cash}, nil
	}

	tx, txErr := b.engine.Pool.Begin(ctx)
	if txErr != nil {
		return &MutationResult{false, "transaction error", cash}, nil
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	_, lerr := b.engine.Ledger.DebitTx(ctx, tx, userID, down, "investing", "aircraft_purchase_deposit",
		fmt.Sprintf("Aircraft financing down payment — %s", modelName), gameTime)
	if lerr != nil {
		return &MutationResult{false, "ledger debit failed", cash}, nil
	}
	var fleetID string
	err = tx.QueryRow(ctx, `
		INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, tail_number, acquisition_type, condition, status, economy_seats, business_seats, first_class_seats)
		VALUES ($1,$2,$3,$4,'finance',100.00,'active',FLOOR($5*0.80),FLOOR($5*0.15),$5-FLOOR($5*0.80)-FLOOR($5*0.15))
		RETURNING id`, userID, p.ModelID, modelName, tail, capacity).Scan(&fleetID)
	if err != nil {
		return &MutationResult{false, "insert aircraft failed", cash}, nil
	}
	_, err = tx.Exec(ctx, `
		INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, loan_type, collateral_aircraft_id, term_months, monthly_payment, originated_game_date)
		VALUES ($1,$2,$3,$4,$5,'active','aircraft_financing',$6,$7,$8,$9)`,
		userID, principal, rate, totalRepayable, weekly, fleetID, p.TermMonths, monthly, gameTime)
	if err != nil {
		return &MutationResult{false, "insert loan failed", cash}, nil
	}
	tx.Commit(ctx) //nolint:errcheck
	newCash, _ := b.engine.Ledger.GetBalance(ctx, userID)
	return &MutationResult{true, "Aircraft financed successfully.", newCash}, nil
}
