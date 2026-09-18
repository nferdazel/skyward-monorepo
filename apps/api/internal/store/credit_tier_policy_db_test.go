package store_test

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"skyward-api/internal/store"
)

// TestCreditReportUsesTierPolicy membuktikan laporan kredit mengikuti tier
// pemain, bukan selalu memakai angka tier Standard.
//
// Ini menangkap bug nyata, bukan sekadar kerapian: dulu `GetCreditReport`
// menulis konstantanya sendiri di dua tempat dan keduanya memakai angka tier
// Standard tanpa melihat tier pemain, sehingga pemain Gold melihat plafon
// Rp 5 juta dan bunga 12% padahal `take_loan` mengizinkan Rp 10 juta dan 5%.
// Laporan yang dibaca pemain bisa berbeda dari yang akan dieksekusi server.
//
// Nilai harapan diambil dari `credit_tier_config`; kalau config diubah, test ini
// harus ikut berubah — itu memang tujuannya.
//
// Butuh `TEST_DATABASE_URL`; skip di CI seperti konvensi di ci.yml.
func TestCreditReportUsesTierPolicy(t *testing.T) {
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

	tiers := []struct {
		tier          string
		wantUnsecured float64
		wantRate      float64
	}{
		{"Standard", 5000000, 0.12},
		{"Silver", 7000000, 0.08},
		{"Gold", 10000000, 0.05},
		{"Platinum", 15000000, 0.03},
	}

	for _, tc := range tiers {
		t.Run(tc.tier, func(t *testing.T) {
			const uname = "dry4_tier_probe"
			if _, err := pool.Exec(ctx, `DELETE FROM users WHERE username=$1`, uname); err != nil {
				t.Fatal(err)
			}
			var uid string
			if err := pool.QueryRow(ctx, `
				INSERT INTO users (username, password_hash, company_name, ceo_name,
				                   hq_airport_iata, game_current_time, actor_type, onboarding_completed)
				VALUES ($1,'x','Dry4 Air','Ceo','CGK',NOW(),'REAL',true) RETURNING id`,
				uname).Scan(&uid); err != nil {
				t.Fatal(err)
			}
			defer pool.Exec(ctx, `DELETE FROM users WHERE id=$1`, uid)

			if _, err := pool.Exec(ctx, `
				INSERT INTO credit_scores (user_id, score, tier, fleet_health_score,
				    revenue_stability_score, debt_ratio_score, cash_reserves_score, profit_history_score)
				VALUES ($1, 700, $2, 100,100,100,100,100)
				ON CONFLICT (user_id) DO UPDATE SET tier=EXCLUDED.tier`, uid, tc.tier); err != nil {
				t.Fatal(err)
			}

			cr, err := s.GetCreditReport(ctx, uid)
			if err != nil {
				t.Fatal(err)
			}
			t.Logf("%s: plafon=%.0f bunga=%.2f min=%.0f maxActive=%d",
				tc.tier, cr.MaxUnsecuredLoan, cr.UnsecuredRate, cr.MinLoanAmount, cr.MaxActiveLoans)

			if cr.Tier != tc.tier {
				t.Errorf("tier laporan %q, mau %q", cr.Tier, tc.tier)
			}
			if cr.MaxUnsecuredLoan != tc.wantUnsecured {
				t.Errorf("plafon %.0f, mau %.0f (tier %s)", cr.MaxUnsecuredLoan, tc.wantUnsecured, tc.tier)
			}
			if cr.UnsecuredRate != tc.wantRate {
				t.Errorf("bunga %.2f, mau %.2f (tier %s)", cr.UnsecuredRate, tc.wantRate, tc.tier)
			}
			if cr.MaxActiveLoans != 3 {
				t.Errorf("max active loans %d, mau 3", cr.MaxActiveLoans)
			}
			if cr.MinLoanAmount != 100000 {
				t.Errorf("min loan %.0f, mau 100000", cr.MinLoanAmount)
			}
		})
	}

	// Pemain tanpa riwayat kredit: harus konservatif (Standard), bukan tinggi.
	t.Run("tanpa riwayat", func(t *testing.T) {
		const uname = "dry4_nohistory"
		if _, err := pool.Exec(ctx, `DELETE FROM users WHERE username=$1`, uname); err != nil {
			t.Fatal(err)
		}
		var uid string
		if err := pool.QueryRow(ctx, `
			INSERT INTO users (username, password_hash, company_name, ceo_name,
			                   hq_airport_iata, game_current_time, actor_type, onboarding_completed)
			VALUES ($1,'x','Dry4 NoHist','Ceo','CGK',NOW(),'REAL',true) RETURNING id`,
			uname).Scan(&uid); err != nil {
			t.Fatal(err)
		}
		defer pool.Exec(ctx, `DELETE FROM users WHERE id=$1`, uid)

		cr, err := s.GetCreditReport(ctx, uid)
		if err != nil {
			t.Fatal(err)
		}
		if cr.HasHistory {
			t.Error("pemain baru tidak boleh punya riwayat kredit")
		}
		if cr.MaxUnsecuredLoan != 5000000 || cr.UnsecuredRate != 0.12 {
			t.Errorf("tanpa riwayat harus Standard: plafon=%.0f bunga=%.2f",
				cr.MaxUnsecuredLoan, cr.UnsecuredRate)
		}
	})
}
