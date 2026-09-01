// Package engine — sole business logic Skyward.
// Fase 5: mutation surface (fleet, routes, settings, bank) — faithful ke SQL.
package engine

import (
	"context"
	"fmt"
	"math/rand"
	"time"

	"skyward-api/internal/store"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Engine — root engine; aggregates services.
type Engine struct {
	Store    *store.Store
	Pool     *pgxpool.Pool
	Ledger   *LedgerService
	Fleet    *FleetService
	Routes   *RoutesService
	Settings *SettingsService
	Bank     *BankService
	Hub      Broadcaster // opsional — realtime notification
}

// Broadcaster — interface broadcast (diimplementasi realtime.Hub).
type Broadcaster interface {
	Broadcast(channel, event string)
	BroadcastAll(event string)
}

// New — create engine.
func New(pool *pgxpool.Pool, st *store.Store) *Engine {
	e := &Engine{Pool: pool, Store: st}
	e.Ledger = &LedgerService{engine: e}
	e.Fleet = &FleetService{engine: e}
	e.Routes = &RoutesService{engine: e}
	e.Settings = &SettingsService{engine: e}
	e.Bank = &BankService{engine: e}
	return e
}

// ── Ledger ───────────────────────────────────────────────────────────

type LedgerService struct{ engine *Engine }

func (l *LedgerService) GetBalance(ctx context.Context, userID string) (float64, error) {
	var b float64
	err := l.engine.Pool.QueryRow(ctx,
		`SELECT COALESCE(balance, 0) FROM bank_accounts WHERE user_id=$1 AND account_type='operating' LIMIT 1`, userID).Scan(&b)
	return b, err
}

// DebitTx — debit dalam transaksi (mirror debit_bank_account).
func (l *LedgerService) DebitTx(ctx context.Context, tx pgx.Tx, userID string, amount float64, ifrsCat, ifrsSubcat, desc string, gameTime time.Time) (float64, error) {
	return l.applyTx(ctx, tx, userID, amount, ifrsCat, ifrsSubcat, desc, gameTime, false)
}

// CreditTx — credit dalam transaksi (mirror credit_bank_account).
func (l *LedgerService) CreditTx(ctx context.Context, tx pgx.Tx, userID string, amount float64, ifrsCat, ifrsSubcat, desc string, gameTime time.Time) (float64, error) {
	return l.applyTx(ctx, tx, userID, amount, ifrsCat, ifrsSubcat, desc, gameTime, true)
}

func (l *LedgerService) applyTx(ctx context.Context, tx pgx.Tx, userID string, amount float64, ifrsCat, ifrsSubcat, desc string, gameTime time.Time, credit bool) (float64, error) {
	if amount < 0 {
		return 0, fmt.Errorf("amount must be non-negative: %v", amount)
	}
	if amount == 0 {
		var b float64
		err := tx.QueryRow(ctx, `SELECT COALESCE(balance,0) FROM bank_accounts WHERE user_id=$1 AND account_type='operating' LIMIT 1`, userID).Scan(&b)
		return b, err
	}
	op := "-"
	if credit {
		op = "+"
	}
	var newBalance float64
	err := tx.QueryRow(ctx, fmt.Sprintf(
		`UPDATE bank_accounts SET balance = balance %s $1 WHERE user_id=$2 AND account_type='operating' RETURNING balance`, op),
		amount, userID).Scan(&newBalance)
	if err != nil {
		return 0, fmt.Errorf("ledger update: %w", err)
	}
	txType := "debit"
	ledgerAmount := -amount
	if credit {
		txType = "credit"
		ledgerAmount = amount
	}
	_, err = tx.Exec(ctx, `
		INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, game_date, ifrs_category, ifrs_subcategory)
		SELECT id, $1::uuid, $2::text, $3::numeric, $4::numeric, $5::text, $6::timestamptz, $7::text, $8::text
		FROM bank_accounts WHERE user_id=$1::uuid AND account_type='operating' LIMIT 1`,
		userID, txType, ledgerAmount, newBalance, desc, gameTime, ifrsCat, ifrsSubcat)
	return newBalance, err
}

// DebitAccount — debit tanpa tx eksplisit (dipakai simulation loop per-rute).
func (l *LedgerService) DebitAccount(ctx context.Context, userID string, amount float64, ifrsCat, ifrsSubcat, desc string, gameTime time.Time) (float64, error) {
	tx, err := l.engine.Pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	bal, err := l.DebitTx(ctx, tx, userID, amount, ifrsCat, ifrsSubcat, desc, gameTime)
	if err != nil {
		return 0, err
	}
	return bal, tx.Commit(ctx)
}

// CreditAccount — credit tanpa tx eksplisit (dipakai simulation loop per-rute).
func (l *LedgerService) CreditAccount(ctx context.Context, userID string, amount float64, ifrsCat, ifrsSubcat, desc string, gameTime time.Time) (float64, error) {
	tx, err := l.engine.Pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	bal, err := l.CreditTx(ctx, tx, userID, amount, ifrsCat, ifrsSubcat, desc, gameTime)
	if err != nil {
		return 0, err
	}
	return bal, tx.Commit(ctx)
}

func (l *LedgerService) GenerateTailNumber(ctx context.Context, hqIATA string) (string, error) {
	prefix, err := l.getHQPrefix(ctx, hqIATA)
	if err != nil {
		return "", err
	}
	const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	for attempts := 0; attempts < 100; attempts++ {
		tail := prefix
		for i := 0; i < 3; i++ {
			tail += string(chars[rand.Intn(len(chars))])
		}
		var exists bool
		l.engine.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM fleet_aircraft WHERE tail_number=$1)`, tail).Scan(&exists)
		if !exists {
			return tail, nil
		}
	}
	return "", fmt.Errorf("could not generate unique tail number after 100 attempts")
}

func (l *LedgerService) getHQPrefix(ctx context.Context, iata string) (string, error) {
	var prefix string
	err := l.engine.Pool.QueryRow(ctx, `SELECT get_hq_prefix($1)`, iata).Scan(&prefix)
	return prefix, err
}

// GetUserGameTime — user game_current_time dengan FOR UPDATE lock.
func (l *LedgerService) GetUserGameTime(ctx context.Context, userID string) (time.Time, error) {
	var t time.Time
	err := l.engine.Pool.QueryRow(ctx, `SELECT game_current_time FROM users WHERE id=$1 FOR UPDATE`, userID).Scan(&t)
	return t, err
}

func deref(s *string, d string) string {
	if s == nil || *s == "" {
		return d
	}
	return *s
}
