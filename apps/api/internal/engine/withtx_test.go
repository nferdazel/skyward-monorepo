package engine

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestWithTxCommitsOnSuccess — kerja di dalam transaksi tersimpan.
func TestWithTxCommitsOnSuccess(t *testing.T) {
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

	const key = "withtx_commit_probe"
	defer pool.Exec(ctx, `DELETE FROM game_config WHERE key=$1`, key)

	got, err := withTx(ctx, pool, func(tx pgx.Tx) (string, bool, error) {
		if _, err := tx.Exec(ctx,
			`INSERT INTO game_config (key, value, category) VALUES ($1, '1'::jsonb, 'test')`,
			key); err != nil {
			return "", false, err
		}
		return "ok", false, nil
	})
	if err != nil {
		t.Fatalf("withTx gagal: %v", err)
	}
	if got != "ok" {
		t.Errorf("hasil %q, mau \"ok\"", got)
	}

	var n int
	if err := pool.QueryRow(ctx,
		`SELECT count(*) FROM game_config WHERE key=$1`, key).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("baris tidak tersimpan setelah commit: count=%d", n)
	}
}

// TestWithTxRollsBackOnError — error teknis membatalkan seluruh kerja.
func TestWithTxRollsBackOnError(t *testing.T) {
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

	const key = "withtx_error_probe"
	defer pool.Exec(ctx, `DELETE FROM game_config WHERE key=$1`, key)
	sentinel := errors.New("gagal di tengah")

	_, err = withTx(ctx, pool, func(tx pgx.Tx) (string, bool, error) {
		if _, err := tx.Exec(ctx,
			`INSERT INTO game_config (key, value, category) VALUES ($1, '1'::jsonb, 'test')`,
			key); err != nil {
			return "", false, err
		}
		return "", false, sentinel
	})
	if !errors.Is(err, sentinel) {
		t.Errorf("error %v, mau %v", err, sentinel)
	}

	var n int
	if err := pool.QueryRow(ctx,
		`SELECT count(*) FROM game_config WHERE key=$1`, key).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("baris tersimpan padahal transaksi gagal: count=%d", n)
	}
}

// TestWithTxRollbackFlagReturnsResultWithoutCommitting — hasil dikembalikan
// (pesan untuk pemain), tapi kerja tidak disimpan. Ini pola "not found" /
// "saldo tidak cukup" yang dipakai banyak mutasi.
func TestWithTxRollbackFlagReturnsResultWithoutCommitting(t *testing.T) {
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

	const key = "withtx_flag_probe"
	defer pool.Exec(ctx, `DELETE FROM game_config WHERE key=$1`, key)

	got, err := withTx(ctx, pool, func(tx pgx.Tx) (string, bool, error) {
		if _, err := tx.Exec(ctx,
			`INSERT INTO game_config (key, value, category) VALUES ($1, '1'::jsonb, 'test')`,
			key); err != nil {
			return "", false, err
		}
		return "pesan untuk pemain", true, nil
	})
	if err != nil {
		t.Fatalf("withTx tidak boleh error saat rollback disengaja: %v", err)
	}
	if got != "pesan untuk pemain" {
		t.Errorf("hasil %q, mau pesan dikembalikan", got)
	}

	var n int
	if err := pool.QueryRow(ctx,
		`SELECT count(*) FROM game_config WHERE key=$1`, key).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("rollback disengaja tapi baris tersimpan: count=%d", n)
	}
}

// TestWithTxRollsBackOnPanic — panic di dalam fn tidak boleh meninggalkan
// transaksi terbuka.
//
// Timeout dipasang pendek dengan sengaja. Kalau `defer tx.Rollback` hilang,
// koneksinya tidak dikembalikan ke pool dan query verifikasi di bawah
// menggantung sampai timeout default (10 menit) — kegagalan yang benar tapi
// lambat dan membingungkan. Dengan 30 detik, regresi itu ketahuan cepat.
func TestWithTxRollsBackOnPanic(t *testing.T) {
	dbURL := os.Getenv("TEST_DATABASE_URL")
	if dbURL == "" {
		t.Skip("TEST_DATABASE_URL tidak diset")
	}
	// Pool dibatasi satu koneksi. Kalau `defer tx.Rollback` hilang, koneksi itu
	// tidak kembali, dan query verifikasi di bawah langsung gagal dengan
	// "pool timeout" alih-alih menggantung sampai batas waktu test (10 menit).
	// Ini membuat regresi ketahuan dalam hitungan detik, bukan menit.
	cfg, err := pgxpool.ParseConfig(dbURL)
	if err != nil {
		t.Fatal(err)
	}
	cfg.MaxConns = 1
	cfg.MinConns = 1
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	// Pool ditutup eksplisit di akhir, BUKAN lewat defer. Kalau `defer` di sini,
	// urutannya jadi: pemeriksaan koneksi bocor dulu, baru pool.Close() yang
	// menggantung tanpa batas karena koneksinya tidak pernah kembali — dan
	// kegagalannya muncul sebagai "test timed out after 10m", bukan sebagai
	// pesan bahwa Rollback hilang. Menutupnya di akhir membuat pesan aslinya
	// yang terlihat.
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	const key = "withtx_panic_probe"
	// Bersihkan sisa run sebelumnya lewat koneksi yang masih tersedia.
	_, _ = pool.Exec(ctx, `DELETE FROM game_config WHERE key=$1`, key)

	func() {
		defer func() {
			if r := recover(); r == nil {
				t.Error("panic seharusnya diteruskan ke pemanggil")
			}
		}()
		withTx(ctx, pool, func(tx pgx.Tx) (string, bool, error) {
			if _, err := tx.Exec(ctx,
				`INSERT INTO game_config (key, value, category) VALUES ($1, '1'::jsonb, 'test')`,
				key); err != nil {
				t.Fatal(err)
			}
			panic("sesuatu meledak")
		})
	}()

	// (a) Koneksi harus kembali ke pool. Kalau `defer tx.Rollback` hilang,
	// koneksinya tetap "acquired" dan pool.Close() di defer akan menggantung
	// sampai batas waktu test (10 menit). Memeriksa Stat() lebih dulu membuat
	// regresi itu ketahuan dalam sekejap, dengan pesan yang jelas.
	leaked := pool.Stat().AcquiredConns()

	// (b) Tidak ada baris yang tersimpan.
	var n int
	var queryErr error
	if leaked == 0 {
		queryErr = pool.QueryRow(ctx,
			`SELECT count(*) FROM game_config WHERE key=$1`, key).Scan(&n)
	}
	// Tutup pool SETELAH semua pemeriksaan. Kalau koneksi bocor, penutupan ini
	// akan menggantung; karena itu pemeriksaan kebocoran di atas harus lebih
	// dulu, dan kita tidak menutup sama sekali saat bocor supaya pesannya jelas.
	if leaked == 0 {
		pool.Close()
	}
	if leaked != 0 {
		t.Fatalf("koneksi tidak kembali ke pool setelah panic: acquired=%d "+
			"(defer Rollback hilang?)", leaked)
	}
	if queryErr != nil {
		t.Fatal(queryErr)
	}
	if n != 0 {
		t.Errorf("panic meninggalkan baris tersimpan: count=%d", n)
	}
}

// TestWithTxErrorSentinels membuktikan Begin dan Commit bisa dibedakan
// pemanggil. Ini penting karena pemanggil memetakan keduanya ke pesan pemain
// yang berbeda ("transaction error" vs "commit failed"), dan sentinel inilah
// yang membuat pemetaan itu mungkin tanpa membongkar string error.
func TestWithTxErrorSentinels(t *testing.T) {
	if !errors.Is(fmt.Errorf("%w: %w", ErrTxBegin, errors.New("koneksi ditolak")), ErrTxBegin) {
		t.Error("ErrTxBegin harus terdeteksi lewat errors.Is")
	}
	if errors.Is(fmt.Errorf("%w: %w", ErrTxBegin, errors.New("x")), ErrTxCommit) {
		t.Error("ErrTxBegin tidak boleh terdeteksi sebagai ErrTxCommit")
	}
	if !errors.Is(fmt.Errorf("%w: %w", ErrTxCommit, errors.New("x")), ErrTxCommit) {
		t.Error("ErrTxCommit harus terdeteksi lewat errors.Is")
	}
	// Error bisnis biasa tidak boleh salah dikenali sebagai kegagalan tahap.
	biz := errors.New("Aircraft not found.")
	if errors.Is(biz, ErrTxBegin) || errors.Is(biz, ErrTxCommit) {
		t.Error("error bisnis tidak boleh terdeteksi sebagai kegagalan transaksi")
	}
}

// TestTxFailureMessage membuktikan pemetaan pesan pemain membedakan tahap.
// Tanpa ini, kegagalan Commit tampil sebagai "transaction error" dan pemain
// (serta log) kehilangan informasi tahap mana yang gagal.
func TestTxFailureMessage(t *testing.T) {
	if got := txFailureMessage(fmt.Errorf("%w: %w", ErrTxCommit, errors.New("x"))); got != "commit failed" {
		t.Errorf("ErrTxCommit -> %q, mau \"commit failed\"", got)
	}
	if got := txFailureMessage(fmt.Errorf("%w: %w", ErrTxBegin, errors.New("x"))); got != "transaction error" {
		t.Errorf("ErrTxBegin -> %q, mau \"transaction error\"", got)
	}
	// Error lain yang sampai ke sini juga tidak boleh salah diklasifikasi.
	if got := txFailureMessage(errors.New("apa saja")); got != "transaction error" {
		t.Errorf("error umum -> %q, mau \"transaction error\"", got)
	}
}
