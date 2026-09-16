// Package testsupport — shared helpers for DB-backed integration tests.
//
// Tests using this package skip themselves unless TEST_DATABASE_URL points at a
// dedicated throwaway Postgres database (e.g. `skyward_test`) with all
// migrations applied. They never touch the production database. See
// docs/operations/runbook.md for setup.
package testsupport

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// EnvDatabaseURL is the env var naming the throwaway integration-test database.
const EnvDatabaseURL = "TEST_DATABASE_URL"

const connectTimeout = 10 * time.Second

// NewTestPool connects to TEST_DATABASE_URL and skips the test when it is unset.
// The pool is closed automatically when the test finishes.
func NewTestPool(t *testing.T) *pgxpool.Pool {
	t.Helper()

	url := os.Getenv(EnvDatabaseURL)
	if url == "" {
		t.Skipf("%s not set — skipping DB integration test", EnvDatabaseURL)
	}

	ctx, cancel := context.WithTimeout(context.Background(), connectTimeout)
	defer cancel()

	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatalf("testsupport: connect: %v", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		t.Fatalf("testsupport: ping: %v", err)
	}
	t.Cleanup(pool.Close)
	return pool
}

// Reset clears player-owned data between integration tests. `users` is the
// parent of every player table, so a single CASCADE truncate resets the domain
// without deleting seeded reference data (aircraft_models, airports, game_config).
func Reset(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), connectTimeout)
	defer cancel()

	if _, err := pool.Exec(ctx, `TRUNCATE TABLE users CASCADE`); err != nil {
		t.Fatalf("testsupport: reset: %v", err)
	}
}

// SeedUser inserts a minimal user and returns its id. `username` mirrors
// production (registration always sets it); the schema allows NULL, but
// GetSimulationState scans it into a non-pointer string.
func SeedUser(t *testing.T, pool *pgxpool.Pool, company, ceo string) string {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), connectTimeout)
	defer cancel()

	var id string
	err := pool.QueryRow(ctx,
		`INSERT INTO users (username, company_name, ceo_name) VALUES ($1, $1, $2) RETURNING id`,
		company, ceo).Scan(&id)
	if err != nil {
		t.Fatalf("testsupport: seed user: %v", err)
	}
	return id
}

// SeedActiveSeason replaces the season clock with a single active season at
// gameTime and returns its id. season_clock is global (not user-scoped), so it
// is not cleared by Reset.
func SeedActiveSeason(t *testing.T, pool *pgxpool.Pool, gameTime time.Time) string {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), connectTimeout)
	defer cancel()

	if _, err := pool.Exec(ctx, `DELETE FROM season_clock`); err != nil {
		t.Fatalf("testsupport: clear season clock: %v", err)
	}
	var id string
	err := pool.QueryRow(ctx, `
		INSERT INTO season_clock (label, current_game_time, status)
		VALUES ('Test Season', $1, 'active')
		RETURNING id`, gameTime).Scan(&id)
	if err != nil {
		t.Fatalf("testsupport: seed active season: %v", err)
	}
	return id
}

// SeedAircraftModel inserts a minimal aircraft model and returns its id.
// `aircraft_models` is reference data and survives Reset, so the insert upserts
// on model_name to stay idempotent across repeated runs.
func SeedAircraftModel(t *testing.T, pool *pgxpool.Pool, modelName string) string {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), connectTimeout)
	defer cancel()

	var id string
	err := pool.QueryRow(ctx, `
		INSERT INTO aircraft_models
			(manufacturer, model_name, type, range_km, capacity, speed_kmh,
			 fuel_burn_per_km, maintenance_cost_per_hour, purchase_price, lease_price_per_month)
		VALUES ('Test', $1, 'regional_jet', 3000, 100, 800, 3.0, 1000, 20000000, 100000)
		ON CONFLICT (model_name) DO UPDATE SET manufacturer = EXCLUDED.manufacturer
		RETURNING id`, modelName).Scan(&id)
	if err != nil {
		t.Fatalf("testsupport: seed aircraft model: %v", err)
	}
	return id
}

// SeedFleetAircraft inserts an owned aircraft and returns its id.
func SeedFleetAircraft(t *testing.T, pool *pgxpool.Pool, userID, modelID, tail string) string {
	t.Helper()
	return seedFleetAircraft(t, pool, userID, modelID, tail, "purchase")
}

// SeedLeasedFleetAircraft inserts a leased aircraft and returns its id.
func SeedLeasedFleetAircraft(t *testing.T, pool *pgxpool.Pool, userID, modelID, tail string) string {
	t.Helper()
	return seedFleetAircraft(t, pool, userID, modelID, tail, "lease")
}

func seedFleetAircraft(t *testing.T, pool *pgxpool.Pool, userID, modelID, tail, acquisitionType string) string {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), connectTimeout)
	defer cancel()

	var id string
	err := pool.QueryRow(ctx, `
		INSERT INTO fleet_aircraft
			(user_id, aircraft_model_id, acquisition_type, tail_number, status)
		VALUES ($1, $2, $3, $4, 'active')
		RETURNING id`, userID, modelID, acquisitionType, tail).Scan(&id)
	if err != nil {
		t.Fatalf("testsupport: seed fleet aircraft: %v", err)
	}
	return id
}

// SeedGameConfig upserts a game_config row (jsonb). Config is global and not
// cleared by Reset, so the key is replaced to stay idempotent.
func SeedGameConfig(t *testing.T, pool *pgxpool.Pool, key, value string) {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), connectTimeout)
	defer cancel()

	if _, err := pool.Exec(ctx, `DELETE FROM game_config WHERE key = $1`, key); err != nil {
		t.Fatalf("testsupport: clear game config: %v", err)
	}
	if _, err := pool.Exec(ctx, `
		INSERT INTO game_config (key, value, category, description)
		VALUES ($1, $2::jsonb, 'test', 'test')`, key, value); err != nil {
		t.Fatalf("testsupport: seed game config: %v", err)
	}
}

// SeedBankAccount sets the operating account balance and returns its id. The
// `create_default_bank_account` trigger already inserts the row on user insert,
// so this upserts rather than inserting.
func SeedBankAccount(t *testing.T, pool *pgxpool.Pool, userID string, balance float64) string {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), connectTimeout)
	defer cancel()

	var id string
	err := pool.QueryRow(ctx, `
		INSERT INTO bank_accounts (user_id, account_type, balance)
		VALUES ($1, 'operating', $2)
		ON CONFLICT (user_id, account_type) DO UPDATE SET balance = EXCLUDED.balance
		RETURNING id`, userID, balance).Scan(&id)
	if err != nil {
		t.Fatalf("testsupport: seed bank account: %v", err)
	}
	return id
}

// SeedBankTransaction inserts a bank transaction row and returns its id.
func SeedBankTransaction(t *testing.T, pool *pgxpool.Pool, accountID, userID string, amount float64, ifrsCategory string) string {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), connectTimeout)
	defer cancel()

	var id string
	err := pool.QueryRow(ctx, `
		INSERT INTO bank_transactions
			(account_id, user_id, transaction_type, amount, balance_after, game_date, ifrs_category)
		VALUES ($1, $2, 'credit', $3, $3, NOW(), $4)
		RETURNING id`, accountID, userID, amount, ifrsCategory).Scan(&id)
	if err != nil {
		t.Fatalf("testsupport: seed bank transaction: %v", err)
	}
	return id
}
