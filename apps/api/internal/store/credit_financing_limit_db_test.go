package store_test

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"skyward-api/internal/store"
)

// TestCreditReportCarriesFinancingLimit membuktikan laporan kredit mengirim
// plafon pembiayaan yang dipakai server, bukan membiarkan klien menebak.
//
// Bug yang ditangkap: `GET /bank/credit` tidak pernah mengirim
// `max_financing_amount`, sementara klien membacanya dengan nilai cadangan
// 25.000.000. Nilai cadangan itu kebetulan sama dengan tier Standard, jadi
// pemain Standard tidak terpengaruh, tapi pemain Gold (plafon 75 juta) melihat
// UI menolak pembiayaan di atas 25 juta padahal `POST /bank/finance-aircraft`
// mengizinkan. Plafon yang sama juga dipakai `BankService.FinanceAircraft`
// lewat `tierRate(..., "max_secured", ...)`, jadi field ini harus sama persis
// dengan `max_secured` di `credit_tier_config`.
//
// Butuh `TEST_DATABASE_URL`; skip di CI seperti konvensi di ci.yml.
func TestCreditReportCarriesFinancingLimit(t *testing.T) {
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

	const uname = "finance_limit_probe"
	cleanup := func() {
		_, _ = pool.Exec(ctx, `DELETE FROM credit_scores WHERE user_id IN (SELECT id FROM users WHERE username=$1)`, uname)
		_, _ = pool.Exec(ctx, `DELETE FROM users WHERE username=$1`, uname)
	}
	cleanup()
	defer cleanup()

	var uid string
	if err := pool.QueryRow(ctx, `
		INSERT INTO users (username, password_hash, company_name, ceo_name,
		                   hq_airport_iata, game_current_time, actor_type, onboarding_completed)
		VALUES ($1,'x','Finance Limit','Ceo','CGK',NOW(),'REAL',true) RETURNING id`,
		uname).Scan(&uid); err != nil {
		t.Fatal(err)
	}

	// Nilai harapan dibaca dari config yang sama dengan yang dipakai engine,
	// bukan angka yang saya tulis di test. Kalau config berubah, test ikut.
	for _, tier := range []string{"Standard", "Silver", "Gold", "Platinum"} {
		t.Run(tier, func(t *testing.T) {
			if _, err := pool.Exec(ctx, `
				INSERT INTO credit_scores (user_id, score, tier, fleet_health_score,
				    revenue_stability_score, debt_ratio_score, cash_reserves_score, profit_history_score)
				VALUES ($1, 700, $2, 100,100,100,100,100)
				ON CONFLICT (user_id) DO UPDATE SET tier=EXCLUDED.tier`, uid, tier); err != nil {
				t.Fatal(err)
			}

			var wantSecured float64
			if err := pool.QueryRow(ctx, `
				SELECT (value->$1->>'max_secured')::numeric
				FROM game_config WHERE key='credit_tier_config'`, tier).Scan(&wantSecured); err != nil {
				t.Fatal(err)
			}

			cr, err := s.GetCreditReport(ctx, uid)
			if err != nil {
				t.Fatal(err)
			}
			t.Logf("%s: max_secured_loan=%.0f max_financing_amount=%.0f",
				tier, cr.MaxSecuredLoan, cr.MaxFinancingAmount)

			if cr.MaxFinancingAmount != wantSecured {
				t.Errorf("max_financing_amount %.0f, mau %.0f (tier %s, dari credit_tier_config)",
					cr.MaxFinancingAmount, wantSecured, tier)
			}
		})
	}

	// Pemain tanpa riwayat kredit: plafon harus ikut kebijakan Standard yang
	// konservatif, bukan 0 dan bukan plafon tinggi.
	t.Run("tanpa riwayat", func(t *testing.T) {
		const noHist = "finance_limit_nohist"
		_, _ = pool.Exec(ctx, `DELETE FROM users WHERE username=$1`, noHist)
		var nid string
		if err := pool.QueryRow(ctx, `
			INSERT INTO users (username, password_hash, company_name, ceo_name,
			                   hq_airport_iata, game_current_time, actor_type, onboarding_completed)
			VALUES ($1,'x','NoHist','Ceo','CGK',NOW(),'REAL',true) RETURNING id`,
			noHist).Scan(&nid); err != nil {
			t.Fatal(err)
		}
		defer pool.Exec(ctx, `DELETE FROM users WHERE id=$1`, nid)

		cr, err := s.GetCreditReport(ctx, nid)
		if err != nil {
			t.Fatal(err)
		}
		var wantStd float64
		if err := pool.QueryRow(ctx, `
			SELECT (value->'Standard'->>'max_secured')::numeric
			FROM game_config WHERE key='credit_tier_config'`).Scan(&wantStd); err != nil {
			t.Fatal(err)
		}
		if cr.MaxFinancingAmount != wantStd {
			t.Errorf("tanpa riwayat: max_financing_amount %.0f, mau %.0f (Standard)",
				cr.MaxFinancingAmount, wantStd)
		}
	})
}
