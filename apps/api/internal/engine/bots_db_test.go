package engine

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"skyward-api/internal/store"
	"skyward-api/internal/testsupport"
)

// seedActor menyisipkan user dengan actor_type dan kolom nullable yang diatur
// eksplisit (hq_airport_iata, auto_grounding_threshold).
func seedActor(t *testing.T, pool *pgxpool.Pool, company, actorType string, hq *string, threshold *float64, gameTime time.Time) string {
	t.Helper()
	var id string
	if err := pool.QueryRow(context.Background(), `
		INSERT INTO users (username, company_name, ceo_name, actor_type,
		                   hq_airport_iata, auto_grounding_threshold, game_current_time)
		VALUES ($1, $1, 'Test CEO', $2, $3, $4, $5)
		RETURNING id`, company, actorType, hq, threshold, gameTime).Scan(&id); err != nil {
		t.Fatalf("seed actor: %v", err)
	}
	return id
}

func gameTimeOf(t *testing.T, pool *pgxpool.Pool, userID string) time.Time {
	t.Helper()
	var ts time.Time
	if err := pool.QueryRow(context.Background(),
		`SELECT game_current_time FROM users WHERE id=$1`, userID).Scan(&ts); err != nil {
		t.Fatalf("read game_current_time: %v", err)
	}
	return ts
}

// TestProcessBots_ProcessesEveryBotDespiteNullProfileFields — regresi: query
// daftar bot mengambil kolom nullable (`hq_airport_iata`,
// `auto_grounding_threshold`) plus kolom `bot_profiles` lewat LEFT JOIN, dan
// error `rows.Scan` diabaikan. Satu baris NULL membuat scan gagal, pgx menutup
// rows, lalu semua bot setelahnya tidak pernah disimulasikan.
func TestProcessBots_ProcessesEveryBotDespiteNullProfileFields(t *testing.T) {
	pool := testsupport.NewTestPool(t)
	testsupport.Reset(t, pool)
	ctx := context.Background()

	target := time.Date(2026, 3, 1, 12, 0, 0, 0, time.UTC)
	testsupport.SeedActiveSeason(t, pool, target)
	// Jangan biarkan tick ini men-spawn bot baru.
	testsupport.SeedGameConfig(t, pool, "max_bot_count", `0`)

	blank := ""
	threshold := 40.0
	before := target.Add(-24 * time.Hour)
	// Bot kedua punya kolom nullable ber-NULL. Urutan iterasi tidak dijamin
	// (query tanpa ORDER BY), jadi assertion-nya adalah "setiap bot yang
	// di-seed harus diproses", bukan "bot setelah baris NULL".
	first := seedActor(t, pool, "Bot One", "AI", &blank, &threshold, before)
	second := seedActor(t, pool, "Bot Two", "AI", nil, nil, before)
	third := seedActor(t, pool, "Bot Three", "AI", &blank, &threshold, before)
	for _, id := range []string{first, second, third} {
		testsupport.SeedBankAccount(t, pool, id, 5_000_000)
	}

	eng := New(pool, store.New(pool))
	if _, err := eng.ProcessBots(ctx, target); err != nil {
		t.Fatalf("ProcessBots: %v", err)
	}

	for _, tc := range []struct{ name, id string }{
		{"bot pertama", first},
		{"bot kedua (kolom NULL)", second},
		{"bot ketiga", third},
	} {
		if got := gameTimeOf(t, pool, tc.id); !got.Equal(target) {
			t.Fatalf("%s: game_current_time = %v, want %v (bot terlewat?)", tc.name, got, target)
		}
	}
}

// TestProcessPlayer_NullAutoGroundingThresholdStillAdvances — regresi: kolom
// nullable itu di-scan ke `float64` tanpa COALESCE, sehingga satu user ber-NULL
// gagal memuat barisnya dan seluruh simulasinya di-rollback setiap tick.
func TestProcessPlayer_NullAutoGroundingThresholdStillAdvances(t *testing.T) {
	pool := testsupport.NewTestPool(t)
	testsupport.Reset(t, pool)
	ctx := context.Background()

	target := time.Date(2026, 3, 1, 12, 0, 0, 0, time.UTC)
	testsupport.SeedActiveSeason(t, pool, target)
	user := seedActor(t, pool, "Threshold Air", "REAL", nil, nil, target.Add(-24*time.Hour))
	testsupport.SeedBankAccount(t, pool, user, 5_000_000)

	eng := New(pool, store.New(pool))
	if _, err := eng.ProcessPlayer(ctx, user, target); err != nil {
		t.Fatalf("ProcessPlayer: %v", err)
	}
	if got := gameTimeOf(t, pool, user); !got.Equal(target) {
		t.Fatalf("game_current_time = %v, want %v", got, target)
	}
}

// TestBotHandlePricing_CancelledContextIsSafe — penjaga, bukan regresi: error
// query dulu dibuang tanpa log, dan saya menduga `rows` yang error membuat
// `defer rows.Close()` panic. Dugaan itu TIDAK terbukti — pgxpool mengembalikan
// rows non-nil dan melaporkan error lewat Next/Err, jadi test ini lulus sebelum
// maupun sesudah perbaikan. Tetap dipertahankan supaya jalur itu tidak berubah
// jadi panic di kemudian hari.
func TestBotHandlePricing_CancelledContextIsSafe(t *testing.T) {
	pool := testsupport.NewTestPool(t)
	testsupport.Reset(t, pool)

	blank := ""
	threshold := 40.0
	bot := seedActor(t, pool, "Cancel Bot", "AI", &blank, &threshold, time.Now())

	eng := New(pool, store.New(pool))
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("botHandlePricing panic saat context dibatalkan: %v", r)
		}
	}()
	eng.botHandlePricing(ctx, bot, time.Now(), "Balanced", "stable", 1.0, 0.20)
}
