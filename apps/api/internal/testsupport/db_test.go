package testsupport_test

import (
	"context"
	"testing"

	"skyward-api/internal/testsupport"
)

// TestHarnessSeedsAndResets is the harness' own smoke test: it proves the
// connection, the CASCADE reset and the seed helpers work against a real
// schema. Without it, a green `go test ./...` could mean the DB-backed tests
// all skipped.
func TestHarnessSeedsAndResets(t *testing.T) {
	pool := testsupport.NewTestPool(t)
	testsupport.Reset(t, pool)
	ctx := context.Background()

	user := testsupport.SeedUser(t, pool, "Harness Air", "Test CEO")
	model := testsupport.SeedAircraftModel(t, pool, "Harness Jet")
	aircraft := testsupport.SeedFleetAircraft(t, pool, user, model, "HX-001")
	account := testsupport.SeedBankAccount(t, pool, user, 1_000_000)

	var company, tail string
	var balance float64
	if err := pool.QueryRow(ctx, `
		SELECT u.company_name, f.tail_number, b.balance
		FROM users u
		JOIN fleet_aircraft f ON f.user_id = u.id
		JOIN bank_accounts  b ON b.user_id = u.id
		WHERE u.id = $1 AND f.id = $2 AND b.id = $3`,
		user, aircraft, account).Scan(&company, &tail, &balance); err != nil {
		t.Fatalf("read back seeded rows: %v", err)
	}
	if company != "Harness Air" || tail != "HX-001" || balance != 1_000_000 {
		t.Fatalf("seeded rows = company %q tail %q balance %v", company, tail, balance)
	}

	// Config is global, so Reset must leave it alone; clean it up ourselves so
	// repeated runs leave the test database tidy.
	testsupport.SeedGameConfig(t, pool, "harness_test_key", `1`)
	t.Cleanup(func() {
		if _, err := pool.Exec(context.Background(),
			`DELETE FROM game_config WHERE key = 'harness_test_key'`); err != nil {
			t.Logf("cleanup harness_test_key: %v", err)
		}
	})

	testsupport.Reset(t, pool)

	var users int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM users`).Scan(&users); err != nil {
		t.Fatalf("count users: %v", err)
	}
	if users != 0 {
		t.Fatalf("users = %d after Reset, want 0", users)
	}

	var keys int
	if err := pool.QueryRow(ctx,
		`SELECT count(*) FROM game_config WHERE key = 'harness_test_key'`).Scan(&keys); err != nil {
		t.Fatalf("count config: %v", err)
	}
	if keys != 1 {
		t.Fatalf("global config rows after Reset = %d, want 1 (config is not user-scoped)", keys)
	}
}
