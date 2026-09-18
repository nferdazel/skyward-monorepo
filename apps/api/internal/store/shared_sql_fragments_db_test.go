package store_test

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"skyward-api/internal/store"
)

// TestSharedSqlFragmentsReturnRealValues membuktikan fragmen SQL bersama
// (`operatingBalanceExpr`, `revenue30dExpr`) mengembalikan angka yang benar
// setelah disatukan dari beberapa salinan.
//
// Kenapa ini perlu: ketiga query itu di-JOIN ke alias `u`, dan fragmennya
// menulis `u.id`. Kalau alias pemanggil berubah tanpa fragmennya ikut berubah,
// query masih *valid* secara SQL (kolom `u` tidak ada akan error, tapi
// sebaliknya: fragmen bisa terpasang di query dengan alias berbeda dan gagal
// saat runtime, bukan saat compile). Yang lebih berbahaya, nilai yang salah
// tidak membuat query gagal sama sekali, hanya menghasilkan angka berbeda.
//
// Karena itu test ini menetapkan nilai yang diketahui lewat data uji, lalu
// memanggil metode publik yang memakai fragmen tersebut dan membandingkannya
// dengan nilai yang dibaca langsung dari database.
//
// Butuh `TEST_DATABASE_URL`; skip di CI seperti konvensi di ci.yml.
func TestSharedSqlFragmentsReturnRealValues(t *testing.T) {
	dbURL := os.Getenv("TEST_DATABASE_URL")
	if dbURL == "" {
		t.Skip("TEST_DATABASE_URL tidak diset")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	s := store.New(pool)

	const (
		userID   = "22222222-2222-2222-2222-222222222222"
		username = "frag_tester"
		revenue  = 777333.0
	)

	cleanup := func() {
		_, _ = pool.Exec(ctx, `DELETE FROM bank_transactions WHERE user_id=$1`, userID)
		_, _ = pool.Exec(ctx, `DELETE FROM bank_accounts WHERE user_id=$1`, userID)
		_, _ = pool.Exec(ctx, `DELETE FROM users WHERE id=$1`, userID)
	}
	cleanup()
	defer cleanup()

	// Trigger `create_default_bank_account` membuat akun operating dengan
	// starting_cash dari game_config. Nilai itu yang jadi nilai harapan, bukan
	// angka yang saya tebak, supaya test tidak rapuh kalau seed berubah.
	if _, err := pool.Exec(ctx, `
		INSERT INTO users (id, username, company_name, ceo_name, password_hash,
		                   hq_airport_iata, actor_type, game_current_time, net_worth)
		VALUES ($1, $2, 'Frag Air', 'Tester', 'x', 'CGK', 'REAL', now(), 8888888)`,
		userID, username); err != nil {
		t.Fatal(err)
	}

	var wantBalance, wantRevenue float64
	if err := pool.QueryRow(ctx, `
		SELECT COALESCE((SELECT balance FROM bank_accounts
		                 WHERE user_id=$1 AND account_type='operating' LIMIT 1), 0),
		       COALESCE((SELECT SUM(bt.amount) FROM bank_transactions bt
		                 JOIN users u ON u.id = bt.user_id
		                 WHERE bt.user_id=$1 AND bt.transaction_type='credit'
		                   AND bt.game_date >= u.game_current_time - INTERVAL '30 days'), 0)`,
		userID).Scan(&wantBalance, &wantRevenue); err != nil {
		t.Fatal(err)
	}
	if wantBalance <= 0 {
		t.Fatalf("fixture tidak membuat akun operating berisi saldo (balance=%v)", wantBalance)
	}

	// Dua transaksi, sengaja: satu DI DALAM jendela 30 hari dan satu DI LUAR.
	//
	// `bank_accounts.balance` adalah kas kanonik dan TIDAK ikut berubah saat
	// baris ledger ditulis; yang memindahkan saldo adalah engine. Jadi
	// `wantBalance` sengaja dibiarkan, dan yang bertambah hanya pendapatan.
	//
	// Transaksi di luar jendela itu penting: tanpa itu, menghapus syarat
	// `game_date >= ... - INTERVAL '30 days'` dari fragmen tidak akan mengubah
	// hasil apa pun (semua baris kebetulan masih di dalam jendela), sehingga
	// test akan lulus meskipun jendelanya salah. Sudah dibuktikan: dengan satu
	// transaksi saja, test tetap hijau walau syarat 30 hari dihapus.
	for _, tx := range []struct {
		label string
		days  int
		amt   float64
	}{
		{"dalam jendela", 1, revenue},
		{"di luar jendela", 90, 999999},
	} {
		if _, err := pool.Exec(ctx, `
			INSERT INTO bank_transactions (account_id, user_id, game_date, transaction_type, amount, balance_after)
			SELECT ba.id, ba.user_id, now() - make_interval(days => $2), 'credit', $3, $4
			FROM bank_accounts ba WHERE ba.user_id=$1 AND ba.account_type='operating'`,
			userID, tx.days, tx.amt, wantBalance+tx.amt); err != nil {
			t.Fatalf("insert %s: %v", tx.label, err)
		}
		if tx.days <= 30 {
			wantRevenue += tx.amt
		}
	}

	// 1. GetSimulationState memakai operatingBalanceExpr.
	state, err := s.GetSimulationState(ctx, userID)
	if err != nil {
		t.Fatalf("GetSimulationState: %v", err)
	}
	if state.Cash != wantBalance {
		t.Errorf("operatingBalanceExpr lewat GetSimulationState: dapat %v, ingin %v",
			state.Cash, wantBalance)
	}

	// 2. GetLeaderboard memakai operatingBalanceExpr DAN revenue30dExpr.
	board, err := s.GetLeaderboard(ctx)
	if err != nil {
		t.Fatalf("GetLeaderboard: %v", err)
	}
	var found bool
	for _, e := range board {
		if e.CompanyName != "Frag Air" {
			continue
		}
		found = true
		if e.Cash != wantBalance {
			t.Errorf("operatingBalanceExpr lewat GetLeaderboard: dapat %v, ingin %v",
				e.Cash, wantBalance)
		}
		if e.MonthlyRevenue != wantRevenue {
			t.Errorf("revenue30dExpr lewat GetLeaderboard: dapat %v, ingin %v",
				e.MonthlyRevenue, wantRevenue)
		}
	}
	if !found {
		t.Fatal("pemain uji tidak muncul di leaderboard")
	}

	// 3. GetCompetitorInsight memakai revenue30dExpr.
	insight, err := s.GetCompetitorInsights(ctx, userID, false)
	if err != nil {
		t.Fatalf("GetCompetitorInsights: %v", err)
	}
	if insight.MonthlyRevenue != wantRevenue {
		t.Errorf("revenue30dExpr lewat GetCompetitorInsights: dapat %v, ingin %v",
			insight.MonthlyRevenue, wantRevenue)
	}
}
