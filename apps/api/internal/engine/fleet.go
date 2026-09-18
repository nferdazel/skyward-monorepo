// Package engine — fleet mutations (Fase 5), faithful ke fungsi SQL.
package engine

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"skyward-api/internal/money"
)

// FleetService — fleet mutations.
type FleetService struct{ engine *Engine }

// MutationResult — mirror SQL TABLE(success, message, new_cash).
type MutationResult struct {
	Success bool    `json:"success"`
	Message string  `json:"message"`
	NewCash float64 `json:"new_cash,omitempty"`
}

// repairCostFor, saleValueFor, dan leaseExitFeeFor pindah ke
// `internal/money` supaya lapisan baca (store) dan lapisan ledger (engine)
// memakai rumus yang sama persis, bukan salinan. Lihat header paket money.
func repairCostFor(condition, purchasePrice float64) float64 {
	return money.RepairCostFor(condition, purchasePrice)
}

func saleValueFor(condition, purchasePrice float64, acquiredGameDate *time.Time, gameTime time.Time) float64 {
	return money.SaleValueFor(condition, purchasePrice, acquiredGameDate, gameTime)
}

func leaseExitFeeFor(leasePricePerMonth float64) float64 {
	return money.LeaseExitFeeFor(leasePricePerMonth)
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
// checkTierGate returns a non-empty message when the player's credit tier is
// below the model's required tier (GAME-06). Empty string means allowed. Bots
// are exempt: the gate is a player-progression mechanic, and bots do not have
// credit scores.
func (f *FleetService) checkTierGate(ctx context.Context, userID, minTier, modelName string) string {
	if minTier == "" || creditTierRank(minTier) <= 1 {
		return ""
	}
	var actorType string
	if err := f.engine.Pool.QueryRow(ctx, `SELECT COALESCE(actor_type, 'REAL') FROM users WHERE id=$1`, userID).Scan(&actorType); err != nil {
		// Gagal baca actor_type tidak boleh berarti "bot": itu melewati gate
		// tier sepenuhnya. COALESCE berarti baris kosong = user tidak ada —
		// dua-duanya ditolak.
		return "Credit tier could not be verified. Please try again."
	}
	if actorType != "REAL" {
		return ""
	}
	current := f.engine.CurrentCreditTier(ctx, userID)
	return tierGateMessage(current, minTier, modelName)
}

// tierGateMessage is the pure tier-gate decision: non-empty when the current
// tier is below the required tier.
func tierGateMessage(currentTier, minTier, modelName string) string {
	if minTier == "" || creditTierRank(minTier) <= 1 {
		return ""
	}
	if creditTierRank(currentTier) < creditTierRank(minTier) {
		return fmt.Sprintf("%s requires %s credit tier (you are %s).", modelName, minTier, currentTier)
	}
	return ""
}

func (f *FleetService) Purchase(ctx context.Context, userID string, p PurchaseParams) (*MutationResult, error) {
	var price, capacity float64
	var modelName, minTier string
	err := f.engine.Pool.QueryRow(ctx,
		`SELECT purchase_price, capacity, model_name, min_credit_tier FROM aircraft_models WHERE id=$1`, p.ModelID).
		Scan(&price, &capacity, &modelName, &minTier)
	if err != nil {
		return &MutationResult{Success: false, Message: "Aircraft model not found."}, nil
	}
	if msg := f.checkTierGate(ctx, userID, minTier, modelName); msg != "" {
		return &MutationResult{Success: false, Message: msg}, nil
	}
	econ := capacity
	if p.EconomySeats != nil {
		econ = float64(*p.EconomySeats)
	}
	if err := validateSeats(int(econ), p.BusinessSeats, p.FirstClassSeats, int(capacity)); err != nil {
		return &MutationResult{Success: false, Message: err.Error()}, nil
	}
	cash, _ := f.engine.Ledger.GetBalance(ctx, userID)
	if moneyLessThan(cash, price) {
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

	result, err := withTx(ctx, f.engine.Pool, func(tx pgx.Tx) (*MutationResult, bool, error) {
		newCash, err := f.engine.Ledger.DebitTx(ctx, tx, userID, price, "investing", "aircraft_purchase",
			fmt.Sprintf("Purchased aircraft %s [%s]", modelName, tail), gameTime)
		if err != nil {
			return &MutationResult{Success: false, Message: "ledger debit failed", NewCash: cash}, true, nil
		}
		_, err = tx.Exec(ctx, `
			INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
			VALUES ($1,$2,$3,'purchase',100.00,'active',$4,$5,$6,$7)`,
			userID, p.ModelID, nickname, tail, int(econ), p.BusinessSeats, p.FirstClassSeats)
		if err != nil {
			return &MutationResult{Success: false, Message: "insert aircraft failed", NewCash: cash}, true, nil
		}
		return &MutationResult{Success: true, Message: fmt.Sprintf("Successfully purchased %s [%s]", modelName, tail), NewCash: newCash}, false, nil
	})
	if err != nil {
		return &MutationResult{Success: false, Message: txFailureMessage(err), NewCash: cash}, nil
	}
	return result, nil
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

	gameTimeForSale, _ := f.engine.Ledger.GetUserGameTime(ctx, userID)
	saleValue := saleValueFor(fr.Condition, fr.PurchasePrice, fr.AcquiredGameDate, gameTimeForSale)

	result, err := withTx(ctx, f.engine.Pool, func(tx pgx.Tx) (*MutationResult, bool, error) {
		// AUDIT-08: lock the aircraft row — serializes against Routes.Assign so a
		// plane cannot be sold while being assigned (FK SET NULL ghost route) or
		// double-assigned. The pre-read check above stays only as a fast-fail.
		var lockedID string
		if err := tx.QueryRow(ctx, `SELECT id FROM fleet_aircraft WHERE id=$1 AND user_id=$2 FOR UPDATE`, fleetID, userID).Scan(&lockedID); err != nil {
			return &MutationResult{Success: false, Message: "Aircraft not found."}, true, nil
		}
		var stillAssigned bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM route_assignments WHERE user_id=$1 AND assigned_aircraft_id=$2)`, userID, fleetID).Scan(&stillAssigned); err != nil {
			return &MutationResult{Success: false, Message: "assignment check failed"}, true, nil
		}
		if stillAssigned {
			return &MutationResult{Success: false, Message: "Aircraft is still assigned to a route."}, true, nil
		}

		gameTime, _ := f.engine.Ledger.GetUserGameTime(ctx, userID)
		newCash, err := f.engine.Ledger.CreditTx(ctx, tx, userID, saleValue, "investing", "aircraft_sale",
			fmt.Sprintf("Sold aircraft %s [%s]", fr.ModelName, deref(fr.TailNumber, "NO-TAIL")), gameTime)
		if err != nil {
			return &MutationResult{Success: false, Message: "ledger credit failed"}, true, nil
		}
		_, err = tx.Exec(ctx, `DELETE FROM fleet_aircraft WHERE id=$1 AND user_id=$2`, fleetID, userID)
		if err != nil {
			return &MutationResult{Success: false, Message: "delete aircraft failed"}, true, nil
		}
		return &MutationResult{Success: true, Message: fmt.Sprintf("Aircraft sold for $%.2f.", saleValue), NewCash: newCash}, false, nil
	})
	if err != nil {
		return &MutationResult{Success: false, Message: txFailureMessage(err)}, nil
	}
	return result, nil
}

// Repair — POST /fleet/{id}/repair. Faithful port of perform_actor_aircraft_repair (player path).
func (f *FleetService) Repair(ctx context.Context, userID, fleetID string) (*MutationResult, error) {
	result, err := withTx(ctx, f.engine.Pool, func(tx pgx.Tx) (*MutationResult, bool, error) {
		var condition float64
		var purchasePrice float64
		var modelName string
		err := tx.QueryRow(ctx, `
			SELECT f.condition, m.purchase_price, m.model_name
			FROM fleet_aircraft f JOIN aircraft_models m ON m.id=f.aircraft_model_id
			WHERE f.id=$1 AND f.user_id=$2 FOR UPDATE`, fleetID, userID).
			Scan(&condition, &purchasePrice, &modelName)
		if err != nil {
			return &MutationResult{Success: false, Message: "Aircraft not found."}, true, nil
		}
		cash, _ := f.engine.Ledger.GetBalance(ctx, userID)
		if condition >= 100.0 {
			return &MutationResult{Success: true, Message: fmt.Sprintf("Aircraft %s is already in pristine condition (100%%).", modelName), NewCash: cash}, true, nil
		}
		// Repair is priced off the aircraft's value, not its monthly lease rent.
		// Leased aircraft already carry higher wear (leased_wear_per_flight_cycle),
		// which is the intended differentiator. See repairCostFor.
		repairCost := repairCostFor(condition, purchasePrice)
		if moneyLessThan(cash, repairCost) {
			return &MutationResult{Success: false,
				Message: fmt.Sprintf("Insufficient funds for repair. Required: $%.2f", repairCost), NewCash: cash}, true, nil
		}

		gameTime, _ := f.engine.Ledger.GetUserGameTime(ctx, userID)
		desc := fmt.Sprintf("Maintenance completed for %s - restored from %.2f%% to 100%%", modelName, condition)
		newCash, err := f.engine.Ledger.DebitTx(ctx, tx, userID, repairCost, "cogs", "maintenance", desc, gameTime)
		if err != nil {
			return &MutationResult{Success: false, Message: "ledger debit failed", NewCash: cash}, true, nil
		}
		_, err = tx.Exec(ctx, `UPDATE fleet_aircraft SET condition=100.00, status='active' WHERE id=$1 AND user_id=$2`, fleetID, userID)
		if err != nil {
			return &MutationResult{Success: false, Message: "update aircraft failed", NewCash: cash}, true, nil
		}
		return &MutationResult{Success: true, Message: "Aircraft maintenance complete. Health restored to 100%!", NewCash: newCash}, false, nil
	})
	if err != nil {
		return &MutationResult{Success: false, Message: txFailureMessage(err)}, nil
	}
	return result, nil
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
	var modelName, minTier string
	err := f.engine.Pool.QueryRow(ctx,
		`SELECT lease_price_per_month, purchase_price, capacity, model_name, min_credit_tier FROM aircraft_models WHERE id=$1`, p.ModelID).
		Scan(&leasePrice, &purchasePrice, &capacity, &modelName, &minTier)
	if err != nil {
		return &MutationResult{false, "Aircraft model not found.", 0}, nil
	}
	if msg := f.checkTierGate(ctx, userID, minTier, modelName); msg != "" {
		return &MutationResult{false, msg, 0}, nil
	}
	econ := capacity
	if p.EconomySeats != nil {
		econ = float64(*p.EconomySeats)
	}
	if err := validateSeats(int(econ), p.BusinessSeats, p.FirstClassSeats, int(capacity)); err != nil {
		return &MutationResult{false, err.Error(), 0}, nil
	}
	deposit := calcLeaseDeposit(purchasePrice, leasePrice,
		f.engine.getConfigNum(ctx, "base_lease_deposit_percentage", 0.10))
	cash, _ := f.engine.Ledger.GetBalance(ctx, userID)
	if moneyLessThan(cash, deposit) {
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
	result, err := withTx(ctx, f.engine.Pool, func(tx pgx.Tx) (*MutationResult, bool, error) {
		_, lerr := f.engine.Ledger.DebitTx(ctx, tx, userID, deposit, "investing", "aircraft_lease_deposit",
			fmt.Sprintf("Leased aircraft %s deposit [%s]", modelName, tail), gameTime)
		if lerr != nil {
			return &MutationResult{false, "ledger debit failed", cash}, true, nil
		}
		_, err = tx.Exec(ctx, `
			INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
			VALUES ($1,$2,$3,'lease',100.00,'active',$4,$5,$6,$7)`,
			userID, p.ModelID, p.Nickname, tail, int(econ), p.BusinessSeats, p.FirstClassSeats)
		if err != nil {
			return &MutationResult{false, "insert aircraft failed", cash}, true, nil
		}
		return nil, false, nil
	})
	if err != nil {
		return &MutationResult{false, txFailureMessage(err), cash}, nil
	}
	if result != nil {
		return result, nil
	}
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
	exitFee := leaseExitFeeFor(leasePrice)
	cash, _ := f.engine.Ledger.GetBalance(ctx, userID)
	if moneyLessThan(cash, exitFee) {
		return &MutationResult{false, "Insufficient funds to pay lease termination fee.", cash}, nil
	}
	result, err := withTx(ctx, f.engine.Pool, func(tx pgx.Tx) (*MutationResult, bool, error) {
		// AUDIT-08 (jalur terminate): kunci baris pesawat lalu cek assignment DI
		// DALAM tx, seperti Fleet.Sell. FK-nya ON DELETE SET NULL, jadi menghapus
		// pesawat yang masih dipakai meninggalkan route hantu tanpa pesawat — dan
		// pre-check di atas mengabaikan error bacanya.
		var lockedID string
		if err := tx.QueryRow(ctx, `SELECT id FROM fleet_aircraft WHERE id=$1 AND user_id=$2 FOR UPDATE`, fleetID, userID).Scan(&lockedID); err != nil {
			return &MutationResult{false, "Aircraft not found.", cash}, true, nil
		}
		var stillAssigned bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM route_assignments WHERE user_id=$1 AND assigned_aircraft_id=$2)`, userID, fleetID).Scan(&stillAssigned); err != nil {
			return &MutationResult{false, "assignment check failed", cash}, true, nil
		}
		if stillAssigned {
			return &MutationResult{false, "Aircraft is still assigned to a route.", cash}, true, nil
		}
		gameTime, _ := f.engine.Ledger.GetUserGameTime(ctx, userID)
		newCash, debitErr := f.engine.Ledger.DebitTx(ctx, tx, userID, exitFee, "opex", "lease_termination",
			fmt.Sprintf("Terminated leased aircraft %s [%s]", modelName, deref(tail, "NO-TAIL")), gameTime)
		if debitErr != nil {
			return &MutationResult{false, "debit fee failed: " + debitErr.Error(), cash}, true, nil
		}
		_, delErr := tx.Exec(ctx, `DELETE FROM fleet_aircraft WHERE id=$1 AND user_id=$2`, fleetID, userID)
		if delErr != nil {
			return &MutationResult{false, "delete aircraft failed", cash}, true, nil
		}
		return &MutationResult{true, "Lease terminated successfully!", newCash}, false, nil
	})
	if err != nil {
		return &MutationResult{false, txFailureMessage(err), cash}, nil
	}
	return result, nil
}

// basePct = `base_lease_deposit_percentage` dari game_config; bracket persentase
// aset tetap hardcoded karena versi SQL-nya (calculate_required_lease_deposit)
// juga hardcoded.
func calcLeaseDeposit(purchasePrice, leasePrice, basePct float64) float64 {
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
