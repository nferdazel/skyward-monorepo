package engine

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestDemandCurveFromDBMatchesFallback membuktikan nilai yang dibaca dari
// game_config menghasilkan demand yang SAMA dengan fallback Go. Ini penjaga
// utama pemindahan konstanta: kalau seed dan fallback berbeda, kalibrasi
// GAME-02 bergeser diam-diam.
func TestDemandCurveFromDBMatchesFallback(t *testing.T) {
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
	e := &Engine{Pool: pool}
	snap, err := e.LoadTickSnapshot(ctx, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	fromDB := demandCurveFrom(snap)
	if fromDB != defaultDemandCurve() {
		t.Fatalf("kurva dari DB %+v != fallback %+v", fromDB, defaultDemandCurve())
	}
	fromDBCrew := crewScaleFrom(snap)
	if fromDBCrew != defaultCrewScale() {
		t.Fatalf("skala crew dari DB %+v != fallback %+v", fromDBCrew, defaultCrewScale())
	}
}
