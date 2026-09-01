// Package engine — settings mutations (Fase 5), faithful ke fungsi SQL.
package engine

import (
	"context"
	"strings"
)

// SettingsService — settings & account mutations.
type SettingsService struct{ engine *Engine }

// SaveParams — input save_airline_settings.
type SaveParams struct {
	CompanyName            string  `json:"company_name"`
	AutoGroundingThreshold float64 `json:"auto_grounding_threshold"`
	HQAirportIATA          string  `json:"hq_airport_iata"`
}

// Save — PATCH /settings. Faithful port of save_airline_settings(p_user_id,...).
func (s *SettingsService) Save(ctx context.Context, userID string, p SaveParams) (*MutationResult, error) {
	company := strings.TrimSpace(p.CompanyName)
	if company == "" {
		return &MutationResult{Success: false, Message: "Company name cannot be empty."}, nil
	}
	if p.AutoGroundingThreshold < 0 || p.AutoGroundingThreshold > 100 {
		return &MutationResult{Success: false, Message: "Invalid auto-grounding threshold."}, nil
	}
	if p.HQAirportIATA != "" {
		var exists bool
		s.engine.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM airports WHERE iata=$1)`, p.HQAirportIATA).Scan(&exists)
		if !exists {
			return &MutationResult{Success: false, Message: "HQ airport not found."}, nil
		}
	}
	_, err := s.engine.Pool.Exec(ctx, `
		UPDATE users SET company_name=$1, auto_grounding_threshold=$2, hq_airport_iata=$3 WHERE id=$4`,
		company, p.AutoGroundingThreshold, p.HQAirportIATA, userID)
	if err != nil {
		return &MutationResult{Success: false, Message: "save settings failed"}, nil
	}
	return &MutationResult{Success: true, Message: "Settings saved."}, nil
}

// Reset — POST /settings/reset. Faithful port of reset_user_airline(p_user_id).
// Wipe fleet, routes, loans, bank history; restore starting cash.
func (s *SettingsService) Reset(ctx context.Context, userID string) (*MutationResult, error) {
	tx, err := s.engine.Pool.Begin(ctx)
	if err != nil {
		return &MutationResult{Success: false, Message: "transaction error"}, nil
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	for _, q := range []string{
		`DELETE FROM fleet_aircraft WHERE user_id=$1`,
		`DELETE FROM route_assignments WHERE user_id=$1`,
		`DELETE FROM loans WHERE user_id=$1`,
		`DELETE FROM bank_transactions WHERE user_id=$1`,
		`UPDATE bank_accounts SET balance = (SELECT COALESCE((value#>>'{}')::numeric, 15000000) FROM game_config WHERE key='starting_cash') WHERE user_id=$1 AND account_type='operating'`,
		`UPDATE users SET game_current_time = (SELECT current_game_time FROM season_clock WHERE status='active' LIMIT 1), net_worth = (SELECT COALESCE((value#>>'{}')::numeric, 15000000) FROM game_config WHERE key='starting_cash') WHERE id=$1`,
	} {
		if _, err := tx.Exec(ctx, q, userID); err != nil {
			return &MutationResult{Success: false, Message: "reset failed"}, nil
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return &MutationResult{Success: false, Message: "commit failed"}, nil
	}
	cash, _ := s.engine.Ledger.GetBalance(ctx, userID)
	return &MutationResult{Success: true, Message: "Airline reset complete.", NewCash: cash}, nil
}

// DeleteAccount — DELETE /account. Faithful port of delete_account (auth-independent).
func (s *SettingsService) DeleteAccount(ctx context.Context, userID string) (bool, error) {
	tx, err := s.engine.Pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
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
		`DELETE FROM bot_profiles WHERE user_id=$1`,
		`DELETE FROM users WHERE id=$1`,
	} {
		if _, err := tx.Exec(ctx, q, userID); err != nil {
			return false, err
		}
	}
	return tx.Commit(ctx) == nil, nil
}
