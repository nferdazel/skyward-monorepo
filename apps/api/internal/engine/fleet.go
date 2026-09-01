// Package engine — fleet mutations (Fase 5), faithful ke fungsi SQL.
package engine

import (
	"context"
	"fmt"
	"strings"
	"time"
)

// FleetService — fleet mutations.
type FleetService struct{ engine *Engine }

// MutationResult — mirror SQL TABLE(success, message, new_cash).
type MutationResult struct {
	Success bool    `json:"success"`
	Message string  `json:"message"`
	NewCash float64 `json:"new_cash,omitempty"`
}

// PurchaseParams — input purchase/lease.
type PurchaseParams struct {
	ModelID         string `json:"model_id"`
	Nickname        string `json:"nickname,omitempty"`
	EconomySeats    *int   `json:"economy_seats,omitempty"`
	BusinessSeats   int    `json:"business_seats"`
	FirstClassSeats int    `json:"first_class_seats"`
}

// validateSeats — mirror seat-slot check: economy + business*2 + first*3 <= capacity.
func validateSeats(economy, business, first, capacity int) error {
	slots := economy + business*2 + first*3
	if economy < 0 || business < 0 || first < 0 || slots <= 0 || slots > capacity {
		return fmt.Errorf("invalid seat configuration for aircraft capacity")
	}
	return nil
}

// Purchase — POST /fleet/purchase. Faithful port of purchase_aircraft(p_user_id,...).
func (f *FleetService) Purchase(ctx context.Context, userID string, p PurchaseParams) (*MutationResult, error) {
	var price, capacity float64
	var modelName string
	err := f.engine.Pool.QueryRow(ctx,
		`SELECT purchase_price, capacity, model_name FROM aircraft_models WHERE id=$1`, p.ModelID).
		Scan(&price, &capacity, &modelName)
	if err != nil {
		return &MutationResult{Success: false, Message: "Aircraft model not found."}, nil
	}
	econ := capacity
	if p.EconomySeats != nil {
		econ = float64(*p.EconomySeats)
	}
	if err := validateSeats(int(econ), p.BusinessSeats, p.FirstClassSeats, int(capacity)); err != nil {
		return &MutationResult{Success: false, Message: err.Error()}, nil
	}
	cash, _ := f.engine.Ledger.GetBalance(ctx, userID)
	if cash < price {
		return &MutationResult{Success: false, Message: fmt.Sprintf("Insufficient funds to purchase %s.", modelName), NewCash: cash}, nil
	}
	var hq *string
	gameTime, err := f.engine.Ledger.GetUserGameTime(ctx, userID)
	if err != nil {
		return &MutationResult{Success: false, Message: "User not found."}, nil
	}
	f.engine.Pool.QueryRow(ctx, `SELECT hq_airport_iata FROM users WHERE id=$1`, userID).Scan(&hq)

	tail, err := f.engine.Ledger.GenerateTailNumber(ctx, deref(hq, "CGK"))
	if err != nil {
		return &MutationResult{Success: false, Message: "tail number generation failed", NewCash: cash}, nil
	}
	nickname := strings.TrimSpace(p.Nickname)

	tx, err := f.engine.Pool.Begin(ctx)
	if err != nil {
		return &MutationResult{Success: false, Message: "transaction error", NewCash: cash}, nil
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	newCash, err := f.engine.Ledger.DebitTx(ctx, tx, userID, price, "investing", "aircraft_purchase",
		fmt.Sprintf("Purchased aircraft %s [%s]", modelName, tail), gameTime)
	if err != nil {
		return &MutationResult{Success: false, Message: "ledger debit failed", NewCash: cash}, nil
	}
	_, err = tx.Exec(ctx, `
		INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
		VALUES ($1,$2,$3,'purchase',100.00,'active',$4,$5,$6,$7)`,
		userID, p.ModelID, nickname, tail, int(econ), p.BusinessSeats, p.FirstClassSeats)
	if err != nil {
		return &MutationResult{Success: false, Message: "insert aircraft failed", NewCash: cash}, nil
	}
	if err := tx.Commit(ctx); err != nil {
		return &MutationResult{Success: false, Message: "commit failed", NewCash: cash}, nil
	}
	return &MutationResult{Success: true, Message: fmt.Sprintf("Successfully purchased %s [%s]", modelName, tail), NewCash: newCash}, nil
}

// Sell — POST /fleet/{id}/sell. Faithful port of sell_actor_aircraft.
func (f *FleetService) Sell(ctx context.Context, userID, fleetID string) (*MutationResult, error) {
	type fleetRow struct {
		ModelName        string
		PurchasePrice    float64
		Condition        float64
		AcquisitionType  string
		TailNumber       *string
		AcquiredGameDate *time.Time
	}
	var fr fleetRow
	err := f.engine.Pool.QueryRow(ctx, `
		SELECT m.model_name, m.purchase_price, f.condition, f.acquisition_type, f.tail_number, f.acquired_game_date
		FROM fleet_aircraft f JOIN aircraft_models m ON m.id=f.aircraft_model_id
		WHERE f.id=$1 AND f.user_id=$2`, fleetID, userID).
		Scan(&fr.ModelName, &fr.PurchasePrice, &fr.Condition, &fr.AcquisitionType, &fr.TailNumber, &fr.AcquiredGameDate)
	if err != nil {
		return &MutationResult{Success: false, Message: "Aircraft not found."}, nil
	}
	if fr.AcquisitionType != "purchase" {
		return &MutationResult{Success: false, Message: "Only owned aircraft can be sold."}, nil
	}
	var assigned bool
	f.engine.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM route_assignments WHERE user_id=$1 AND assigned_aircraft_id=$2)`, userID, fleetID).Scan(&assigned)
	if assigned {
		return &MutationResult{Success: false, Message: "Aircraft is still assigned to a route."}, nil
	}

	baseValue := fr.PurchasePrice * (fr.Condition / 100.0)
	saleValue := baseValue
	if fr.AcquiredGameDate != nil {
		gameTime, err := f.engine.Ledger.GetUserGameTime(ctx, userID)
		if err == nil {
			ageYears := gameTime.Sub(*fr.AcquiredGameDate).Hours() / (365.25 * 24)
			dep := maxf(0.10, 1.0-0.05*ageYears)
			saleValue = round2(baseValue * dep)
		}
	}

	tx, err := f.engine.Pool.Begin(ctx)
	if err != nil {
		return &MutationResult{Success: false, Message: "transaction error"}, nil
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	gameTime, _ := f.engine.Ledger.GetUserGameTime(ctx, userID)
	newCash, err := f.engine.Ledger.CreditTx(ctx, tx, userID, saleValue, "investing", "aircraft_sale",
		fmt.Sprintf("Sold aircraft %s [%s]", fr.ModelName, deref(fr.TailNumber, "NO-TAIL")), gameTime)
	if err != nil {
		return &MutationResult{Success: false, Message: "ledger credit failed"}, nil
	}
	_, err = tx.Exec(ctx, `DELETE FROM fleet_aircraft WHERE id=$1 AND user_id=$2`, fleetID, userID)
	if err != nil {
		return &MutationResult{Success: false, Message: "delete aircraft failed"}, nil
	}
	if err := tx.Commit(ctx); err != nil {
		return &MutationResult{Success: false, Message: "commit failed"}, nil
	}
	return &MutationResult{Success: true, Message: fmt.Sprintf("Aircraft sold for $%.2f.", saleValue), NewCash: newCash}, nil
}

// Repair — POST /fleet/{id}/repair. Faithful port of perform_actor_aircraft_repair (player path).
func (f *FleetService) Repair(ctx context.Context, userID, fleetID string) (*MutationResult, error) {
	tx, err := f.engine.Pool.Begin(ctx)
	if err != nil {
		return &MutationResult{Success: false, Message: "transaction error"}, nil
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	var condition float64
	var acqType string
	var purchasePrice, leasePrice float64
	var modelName string
	err = tx.QueryRow(ctx, `
		SELECT f.condition, f.acquisition_type, m.purchase_price, m.lease_price_per_month, m.model_name
		FROM fleet_aircraft f JOIN aircraft_models m ON m.id=f.aircraft_model_id
		WHERE f.id=$1 AND f.user_id=$2 FOR UPDATE`, fleetID, userID).
		Scan(&condition, &acqType, &purchasePrice, &leasePrice, &modelName)
	if err != nil {
		return &MutationResult{Success: false, Message: "Aircraft not found."}, nil
	}
	cash, _ := f.engine.Ledger.GetBalance(ctx, userID)
	if condition >= 100.0 {
		return &MutationResult{Success: false, Message: fmt.Sprintf("Aircraft %s is already in pristine condition.", modelName), NewCash: cash}, nil
	}
	var repairCost float64
	if acqType == "lease" {
		repairCost = (100.0 - condition) * (leasePrice * 0.50)
	} else {
		repairCost = (100.0 - condition) * (purchasePrice * 0.0005)
	}
	if cash < repairCost {
		return &MutationResult{Success: false,
			Message: fmt.Sprintf("Insufficient funds for repair. Required: $%.2f", repairCost), NewCash: cash}, nil
	}

	gameTime, _ := f.engine.Ledger.GetUserGameTime(ctx, userID)
	desc := fmt.Sprintf("Maintenance completed for %s - restored from %.2f%% to 100%%", modelName, condition)
	newCash, err := f.engine.Ledger.DebitTx(ctx, tx, userID, repairCost, "cogs", "maintenance", desc, gameTime)
	if err != nil {
		return &MutationResult{Success: false, Message: "ledger debit failed", NewCash: cash}, nil
	}
	_, err = tx.Exec(ctx, `UPDATE fleet_aircraft SET condition=100.00, status='active' WHERE id=$1`, fleetID)
	if err != nil {
		return &MutationResult{Success: false, Message: "update aircraft failed", NewCash: cash}, nil
	}
	if err := tx.Commit(ctx); err != nil {
		return &MutationResult{Success: false, Message: "commit failed", NewCash: cash}, nil
	}
	return &MutationResult{Success: true, Message: "Aircraft maintenance complete. Health restored to 100%!", NewCash: newCash}, nil
}

// ConfigureSeats — PATCH /fleet/{id}/seats. Faithful port of configure_aircraft_seats.
func (f *FleetService) ConfigureSeats(ctx context.Context, userID, fleetID string, economy, business, first int) (*MutationResult, error) {
	var capacity int
	err := f.engine.Pool.QueryRow(ctx, `
		SELECT m.capacity FROM fleet_aircraft f JOIN aircraft_models m ON m.id=f.aircraft_model_id
		WHERE f.id=$1 AND f.user_id=$2`, fleetID, userID).Scan(&capacity)
	if err != nil {
		return &MutationResult{Success: false, Message: "Aircraft not found."}, nil
	}
	if err := validateSeats(economy, business, first, capacity); err != nil {
		return &MutationResult{Success: false, Message: err.Error()}, nil
	}
	_, err = f.engine.Pool.Exec(ctx, `
		UPDATE fleet_aircraft SET economy_seats=$1, business_seats=$2, first_class_seats=$3
		WHERE id=$4 AND user_id=$5`, economy, business, first, fleetID, userID)
	if err != nil {
		return &MutationResult{Success: false, Message: "update failed"}, nil
	}
	return &MutationResult{Success: true, Message: "Seat configuration updated."}, nil
}

func maxf(a, b float64) float64 {
	if a > b {
		return a
	}
	return b
}

func round2(v float64) float64 {
	return float64(int(v*100+0.5)) / 100.0
}

// LeaseParams — input lease.
type LeaseParams struct {
	ModelID         string `json:"model_id"`
	Nickname        string `json:"nickname,omitempty"`
	EconomySeats    *int   `json:"economy_seats,omitempty"`
	BusinessSeats   int    `json:"business_seats"`
	FirstClassSeats int    `json:"first_class_seats"`
}

// Lease — POST /fleet/lease. Faithful port of lease_aircraft(p_user_id,...).
func (f *FleetService) Lease(ctx context.Context, userID string, p LeaseParams) (*MutationResult, error) {
	var leasePrice, purchasePrice, capacity float64
	var modelName string
	err := f.engine.Pool.QueryRow(ctx,
		`SELECT lease_price_per_month, purchase_price, capacity, model_name FROM aircraft_models WHERE id=$1`, p.ModelID).
		Scan(&leasePrice, &purchasePrice, &capacity, &modelName)
	if err != nil {
		return &MutationResult{false, "Aircraft model not found.", 0}, nil
	}
	econ := capacity
	if p.EconomySeats != nil {
		econ = float64(*p.EconomySeats)
	}
	if err := validateSeats(int(econ), p.BusinessSeats, p.FirstClassSeats, int(capacity)); err != nil {
		return &MutationResult{false, err.Error(), 0}, nil
	}
	deposit := calcLeaseDeposit(purchasePrice, leasePrice)
	cash, _ := f.engine.Ledger.GetBalance(ctx, userID)
	if cash < deposit {
		return &MutationResult{false, fmt.Sprintf("Insufficient funds for lease deposit of %s. Required: $%.2f", modelName, deposit), cash}, nil
	}
	var hq *string
	gameTime, err := f.engine.Ledger.GetUserGameTime(ctx, userID)
	if err != nil {
		return &MutationResult{false, "User not found.", 0}, nil
	}
	f.engine.Pool.QueryRow(ctx, `SELECT hq_airport_iata FROM users WHERE id=$1`, userID).Scan(&hq)
	tail, err := f.engine.Ledger.GenerateTailNumber(ctx, deref(hq, "CGK"))
	if err != nil {
		return &MutationResult{false, "tail number generation failed", cash}, nil
	}
	tx, txErr := f.engine.Pool.Begin(ctx)
	if txErr != nil {
		return &MutationResult{false, "transaction error", cash}, nil
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	_, lerr := f.engine.Ledger.DebitTx(ctx, tx, userID, deposit, "investing", "aircraft_lease_deposit",
		fmt.Sprintf("Leased aircraft %s deposit [%s]", modelName, tail), gameTime)
	if lerr != nil {
		return &MutationResult{false, "ledger debit failed", cash}, nil
	}
	_, err = tx.Exec(ctx, `
		INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
		VALUES ($1,$2,$3,'lease',100.00,'active',$4,$5,$6,$7)`,
		userID, p.ModelID, p.Nickname, tail, int(econ), p.BusinessSeats, p.FirstClassSeats)
	if err != nil {
		return &MutationResult{false, "insert aircraft failed", cash}, nil
	}
	tx.Commit(ctx) //nolint:errcheck
	newCash, _ := f.engine.Ledger.GetBalance(ctx, userID)
	return &MutationResult{true, fmt.Sprintf("Successfully leased %s [%s]", modelName, tail), newCash}, nil
}

// TerminateLease — POST /fleet/{id}/terminate-lease. Faithful port of terminate_actor_lease.
func (f *FleetService) TerminateLease(ctx context.Context, userID, fleetID string) (*MutationResult, error) {
	var acqType, modelName string
	var tail *string
	var leasePrice float64
	err := f.engine.Pool.QueryRow(ctx, `
		SELECT f.acquisition_type, m.model_name, f.tail_number, m.lease_price_per_month
		FROM fleet_aircraft f JOIN aircraft_models m ON m.id=f.aircraft_model_id
		WHERE f.id=$1 AND f.user_id=$2`, fleetID, userID).
		Scan(&acqType, &modelName, &tail, &leasePrice)
	if err != nil {
		return &MutationResult{false, "Aircraft not found.", 0}, nil
	}
	if acqType != "lease" {
		return &MutationResult{false, "Only leased aircraft can be terminated through this action.", 0}, nil
	}
	var assigned bool
	f.engine.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM route_assignments WHERE user_id=$1 AND assigned_aircraft_id=$2)`, userID, fleetID).Scan(&assigned)
	if assigned {
		return &MutationResult{false, "Aircraft is still assigned to a route.", 0}, nil
	}
	exitFee := round2(leasePrice * 0.25)
	cash, _ := f.engine.Ledger.GetBalance(ctx, userID)
	if cash < exitFee {
		return &MutationResult{false, "Insufficient funds to pay lease termination fee.", cash}, nil
	}
	tx, txErr := f.engine.Pool.Begin(ctx)
	if txErr != nil {
		return &MutationResult{false, "transaction error", cash}, nil
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	gameTime, _ := f.engine.Ledger.GetUserGameTime(ctx, userID)
	newCash, debitErr := f.engine.Ledger.DebitTx(ctx, tx, userID, exitFee, "opex", "lease_termination",
		fmt.Sprintf("Terminated leased aircraft %s [%s]", modelName, deref(tail, "NO-TAIL")), gameTime)
	if debitErr != nil {
		return &MutationResult{false, "debit fee failed: " + debitErr.Error(), cash}, nil
	}
	_, delErr := tx.Exec(ctx, `DELETE FROM fleet_aircraft WHERE id=$1 AND user_id=$2`, fleetID, userID)
	if delErr != nil {
		return &MutationResult{false, "delete aircraft failed", cash}, nil
	}
	if err := tx.Commit(ctx); err != nil {
		return &MutationResult{false, "commit failed", cash}, nil
	}
	return &MutationResult{true, "Lease terminated successfully!", newCash}, nil
}

func calcLeaseDeposit(purchasePrice, leasePrice float64) float64 {
	basePct := 0.10 // base_lease_deposit_percentage from game_config
	monthlyFloor := leasePrice * maxf(2.0, basePct*20.0)
	var assetPct float64
	switch {
	case purchasePrice < 25000000:
		assetPct = 0.02
	case purchasePrice < 60000000:
		assetPct = 0.03
	case purchasePrice < 120000000:
		assetPct = 0.05
	default:
		assetPct = 0.08
	}
	return round2(maxf(monthlyFloor, purchasePrice*assetPct))
}
