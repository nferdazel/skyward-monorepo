package store

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"skyward-api/internal/testsupport"
)

// TestCompetitorInsightsOmitsHQ — regresi 1.9: endpoint insights publik
// (leaderboard) tidak boleh memuat `hq_airport_iata`, karena nilai itu dipakai
// sebagai salah satu faktor pemulihan password (`validateRecoveryCredentials`).
func TestCompetitorInsightsOmitsHQ(t *testing.T) {
	pool := testsupport.NewTestPool(t)
	testsupport.Reset(t, pool)
	ctx := context.Background()

	hq := "CGK"
	user := testsupport.SeedUser(t, pool, "Insight Air", "CEO")
	if _, err := pool.Exec(ctx, `UPDATE users SET hq_airport_iata=$1 WHERE id=$2`, hq, user); err != nil {
		t.Fatalf("set hq: %v", err)
	}

	st := New(pool)
	ci, err := st.GetCompetitorInsights(ctx, user, false)
	if err != nil {
		t.Fatalf("GetCompetitorInsights: %v", err)
	}

	raw, err := json.Marshal(ci)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(raw), "hq_airport_iata") {
		t.Fatalf("hq_airport_iata ikut terkirim di insights publik: %s", raw)
	}
	// Sanity: payload-nya memang terisi, bukan objek kosong.
	if ci.CompanyName != "Insight Air" {
		t.Fatalf("company_name = %q, want Insight Air", ci.CompanyName)
	}
}
