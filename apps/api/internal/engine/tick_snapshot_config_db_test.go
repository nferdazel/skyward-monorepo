package engine

import (
	"context"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// configReadCounter menghitung query yang benar-benar dikirim ke Postgres dan
// menyentuh game_config selama satu pengukuran.
var configReadCounter int64

// cfgCountingTracer menghitung query ke game_config lewat tracer pgx. Ini
// mengukur apa yang benar-benar terjadi, bukan apa yang diasumsikan terjadi.
type cfgCountingTracer struct{}

func (cfgCountingTracer) TraceQueryStart(ctx context.Context, _ *pgx.Conn, d pgx.TraceQueryStartData) context.Context {
	if strings.Contains(d.SQL, "game_config") {
		atomic.AddInt64(&configReadCounter, 1)
	}
	return ctx
}

func (cfgCountingTracer) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) {}

// TestCreditScoreConfigComesFromSnapshotDB membuktikan dua hal yang terpisah,
// dan keduanya perlu:
//
//  1. Jalur tick tidak membaca `game_config` per pemain. Diukur dengan tracer
//     pgx yang menghitung query menyentuh `game_config`.
//  2. Nilai `starting_cash` dari snapshot BENAR-BENAR dipakai, bukan sekadar
//     fallback Go yang kebetulan sama. Dibuktikan dengan mengubah nilai config
//     di database dan memastikan skor kredit ikut berubah.
//
// Poin 2 ada karena versi pertama test ini cacat: `calculateCreditScore` tidak
// pernah mengembalikan `ok=false`, jadi cek `if !ok { t.Fatal }` adalah kode
// mati. Fungsi bisa keluar lebih awal lewat cabang fallback (gagal membaca
// baris user) sebelum menyentuh config, dan test tetap lulus dengan 0 query.
// Tanpa kontrol positif, test hanya membuktikan "tidak ada query", bukan
// "nilai config dipakai".
//
// Butuh `TEST_DATABASE_URL` (database hasil `make migrate`); skip di CI, sama
// seperti konvensi yang tercatat di `.github/workflows/ci.yml`.
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

	// Fixture dibuat oleh test ini supaya bisa dijalankan dari clone bersih +
	// `make migrate`, tanpa langkah manual yang tidak tercatat.
	const fixtureUser = "tick_snapshot_config_test"
	if _, err := pool.Exec(ctx, `DELETE FROM users WHERE username=$1`, fixtureUser); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `
		INSERT INTO users (username, password_hash, company_name, ceo_name,
		                   hq_airport_iata, game_current_time, actor_type, onboarding_completed)
		VALUES ($1, 'x', 'Snapshot Test Air', 'Ceo', 'CGK', NOW(), 'REAL', true)
		RETURNING id`, fixtureUser).Scan(&userID); err != nil {
		t.Fatalf("membuat pemain fixture: %v", err)
	}
	// Akun operasi sudah dibuat trigger saat user di-insert; beri saldo supaya
	// rasio cashReserve terhitung dari angka yang terdefinisi.
	if _, err := pool.Exec(ctx, `
		UPDATE bank_accounts SET balance = 1000
		WHERE user_id = $1 AND account_type = 'operating'`, userID); err != nil {
		t.Fatalf("menyetel saldo fixture: %v", err)
	}
	if err := pool.QueryRow(ctx, `SELECT game_current_time FROM users WHERE id=$1`, userID).
		Scan(&gameTime); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := pool.Exec(ctx, `DELETE FROM users WHERE id=$1`, userID); err != nil {
			t.Errorf("gagal membersihkan fixture: %v", err)
		}
	}()

	e := New(pool, nil)
	snap, err := e.LoadTickSnapshot(ctx, gameTime)
	if err != nil {
		t.Fatalf("LoadTickSnapshot: %v", err)
	}

	// (1) Snapshot harus memuat key ini, bukan mengandalkan fallback.
	if _, ok := snap.cfg["starting_cash"]; !ok {
		t.Fatal("snapshot tidak memuat starting_cash; tick akan memakai fallback, bukan config")
	}
	fromSnapshot := snap.num("starting_cash", -1)
	if fromSnapshot <= 0 {
		t.Fatalf("starting_cash dari snapshot tidak masuk akal: %v", fromSnapshot)
	}

	// (2) Kontrol positif: buktikan nilai itu MEMPENGARUHI skor.
	// cashReserve = 60 + (cash/startingCash)*60, jadi mengubah startingCash
	// harus mengubah skor. Kalau tidak berubah, nilainya tidak benar-benar dipakai.
	base, okBase := e.calculateCreditScore(ctx, userID, snap)
	if !okBase {
		t.Fatal("calculateCreditScore gagal")
	}

	const shifted = 1.0 // dijaga > 0 supaya cabang cashReserve tetap dihitung
	original := e.getConfigNum(ctx, "starting_cash", 25000000.0)
	if original <= 0 {
		t.Fatalf("starting_cash asli tidak masuk akal: %v", original)
	}
	if _, err := pool.Exec(ctx,
		`UPDATE game_config SET value = to_jsonb($1::numeric) WHERE key='starting_cash'`, shifted); err != nil {
		t.Fatal(err)
	}
	defer func() {
		// Selalu kembalikan nilai asli, bahkan kalau test gagal di tengah.
		if _, err := pool.Exec(ctx,
			`UPDATE game_config SET value = to_jsonb($1::numeric) WHERE key='starting_cash'`, original); err != nil {
			t.Errorf("GAGAL MEMULIHKAN starting_cash (%v); perbaiki manual!", err)
		}
	}()

	shiftedSnap, err := e.LoadTickSnapshot(ctx, gameTime)
	if err != nil {
		t.Fatal(err)
	}
	if got := shiftedSnap.num("starting_cash", -1); got != shifted {
		t.Fatalf("snapshot tidak membaca nilai baru: %v (mau %v)", got, shifted)
	}
	changed, okChanged := e.calculateCreditScore(ctx, userID, shiftedSnap)
	if !okChanged {
		t.Fatal("calculateCreditScore gagal pada snapshot kedua")
	}
	if changed.Total == base.Total {
		t.Errorf("skor tidak berubah setelah starting_cash diubah %v -> %v; "+
			"nilai config sepertinya tidak dipakai (skor tetap %d)",
			original, shifted, base.Total)
	}
	t.Logf("kontrol positif: starting_cash %v -> %v mengubah skor %d -> %d",
		original, shifted, base.Total, changed.Total)

	// (3) Jalur snapshot tidak menghasilkan query game_config sama sekali.
	atomic.StoreInt64(&configReadCounter, 0)
	for i := 0; i < 5; i++ {
		if _, ok := e.calculateCreditScore(ctx, userID, snap); !ok {
			t.Fatal("calculateCreditScore gagal")
		}
	}
	if n := atomic.LoadInt64(&configReadCounter); n != 0 {
		t.Errorf("jalur snapshot membaca game_config %d kali; seharusnya 0", n)
	}
	t.Log("5 pemanggilan calculateCreditScore dengan snapshot: 0 query game_config")
}

// helper dibiarkan minimal: pembersihan fixture dilakukan lewat defer di bawah.
