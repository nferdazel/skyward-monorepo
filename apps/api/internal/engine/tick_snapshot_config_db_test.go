package engine

import (
	"context"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Bukti DRY-5: jalur tick tidak lagi membaca `game_config` per pemain.
//
// Bentuk pengujiannya perlu dijelaskan, karena mudah salah mengukurnya:
// `snap.num` pada snapshot nil mengembalikan fallback TANPA query. Jadi
// membandingkan "snapshot vs nil" tidak membuktikan apa pun tentang jumlah
// query. Yang benar-benar membuktikan adalah:
//
//  1. snapshot nyata MEMUAT `starting_cash` (kalau tidak, nilainya akan jadi
//     fallback dan bukan config);
//  2. nilai dari snapshot sama persis dengan yang dibaca `getConfigNum`;
//  3. menjalankan calculateCreditScore dengan snapshot tidak menghasilkan query
//     `game_config` sama sekali.

// configReadCounter menghitung query yang menyentuh game_config.
var configReadCounter int64

type cfgCountingTracer struct{}

func (cfgCountingTracer) TraceQueryStart(ctx context.Context, _ *pgx.Conn, d pgx.TraceQueryStartData) context.Context {
	if stringsContainsGameConfig(d.SQL) {
		atomic.AddInt64(&configReadCounter, 1)
	}
	return ctx
}

func (cfgCountingTracer) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) {}

func stringsContainsGameConfig(sql string) bool {
	const needle = "game_config"
	for i := 0; i+len(needle) <= len(sql); i++ {
		if sql[i:i+len(needle)] == needle {
			return true
		}
	}
	return false
}

func TestCreditScoreConfigComesFromSnapshotDB(t *testing.T) {
	dbURL := os.Getenv("TEST_DATABASE_URL")
	if dbURL == "" {
		t.Skip("TEST_DATABASE_URL tidak diset; test ini butuh database hasil `make migrate` (lihat runbook §6)")
	}
	ctx := context.Background()

	cfg, err := pgxpool.ParseConfig(dbURL)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.Tracer = cfgCountingTracer{}
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()

	var userID string
	var gameTime time.Time
	if err := pool.QueryRow(ctx,
		`SELECT id, game_current_time FROM users WHERE username LIKE 'dry5u%' LIMIT 1`).
		Scan(&userID, &gameTime); err != nil {
		t.Skipf("pemain uji tidak ada: %v", err)
	}

	e := New(pool, nil)

	snap, err := e.LoadTickSnapshot(ctx, gameTime)
	if err != nil {
		t.Fatalf("LoadTickSnapshot: %v", err)
	}

	// (1) Snapshot harus benar-benar memuat key ini, bukan sekadar fallback.
	if _, ok := snap.cfg["starting_cash"]; !ok {
		t.Fatal("snapshot tidak memuat starting_cash; tick akan memakai fallback, bukan config")
	}

	// (2) Nilai snapshot harus sama dengan yang dibaca langsung dari config.
	fromSnapshot := snap.num("starting_cash", -1)
	fromConfig := e.getConfigNum(ctx, "starting_cash", -1)
	if fromSnapshot != fromConfig {
		t.Errorf("nilai beda: snapshot %v vs getConfigNum %v", fromSnapshot, fromConfig)
	}
	t.Logf("starting_cash: snapshot=%v getConfigNum=%v", fromSnapshot, fromConfig)

	// (3) Jalur snapshot: hitung query game_config SETELAH snapshot dimuat.
	atomic.StoreInt64(&configReadCounter, 0)
	for i := 0; i < 5; i++ {
		if _, ok := e.calculateCreditScore(ctx, userID, snap); !ok {
			t.Fatal("calculateCreditScore gagal")
		}
	}
	queries := atomic.LoadInt64(&configReadCounter)
	if queries != 0 {
		t.Errorf("jalur snapshot membaca game_config %d kali; seharusnya 0", queries)
	}
	t.Log("5 pemanggilan calculateCreditScore dengan snapshot: 0 query game_config")
}
