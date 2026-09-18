package engine

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"os"
	"testing"

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
func TestWithTxRollsBackOnPanic(t *testing.T) {
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

	const key = "withtx_panic_probe"
	defer pool.Exec(ctx, `DELETE FROM game_config WHERE key=$1`, key)

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

	var n int
	if err := pool.QueryRow(ctx,
		`SELECT count(*) FROM game_config WHERE key=$1`, key).Scan(&n); err != nil {
		t.Fatal(err)
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
