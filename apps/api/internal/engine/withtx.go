// Pembungkus transaksi untuk paket engine.
//
// Sebelum ini, 17 tempat menulis urutan yang sama: Begin, defer Rollback, kerja,
// Commit. Empat belas di antaranya identik; tiga sisanya memanggil Rollback
// manual di beberapa cabang (dua di dayboundary.go bahkan kembar kata per kata)
// dan justru itulah yang rapuh — setiap jalur keluar baru harus ingat memanggil
// Rollback sendiri, dan lupa berarti transaksi menggantung sampai koneksinya
// ditutup.
//
// withTx memindahkan keputusan itu ke satu tempat. Pemanggil hanya mengisi
// fungsinya; Begin, Rollback, dan Commit tidak lagi tersebar.
//
// Bentuk generik dipakai supaya tiga pola return yang berbeda tidak memaksa
// tiga varian helper: `*MutationResult`, `bool`, dan `PlayerProcessResult`.
package engine

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// errTxRollback menandai bahwa hasil `fn` harus dibatalkan, bukan di-commit.
//
// `fn` mengembalikan `rollback=true` untuk kasus yang bukan error teknis —
// misalnya pesawat tidak ditemukan atau saldo tidak cukup. Kasus seperti itu
// punya pesan sendiri untuk pemain dan bukan kegagalan sistem, jadi tidak pantas
// jadi `error`; tapi transaksinya tetap tidak boleh di-commit.
// ErrTxBegin dan ErrTxCommit menandai tahap mana yang gagal.
//
// Pemisahan ini ada supaya pemanggil bisa memetakan pesan seperti sebelumnya
// (`"transaction error"` saat Begin gagal, `"commit failed"` saat Commit gagal)
// tanpa harus membongkar string. Sebelum helper ini, kedua tahap punya pesan
// masing-masing; tanpa sentinel, keduanya runtuh jadi satu pesan dan itu
// penurunan kualitas yang tidak perlu.
var (
	ErrTxBegin  = errors.New("begin tx")
	ErrTxCommit = errors.New("commit tx")
)

func withTx[T any](
	ctx context.Context,
	pool *pgxpool.Pool,
	fn func(tx pgx.Tx) (result T, rollback bool, err error),
) (T, error) {
	var zero T

	tx, err := pool.Begin(ctx)
	if err != nil {
		return zero, fmt.Errorf("%w: %w", ErrTxBegin, err)
	}
	// Rollback setelah Commit adalah no-op di pgx, jadi defer ini aman sebagai
	// jaring pengaman untuk semua jalur keluar, termasuk panic.
	defer tx.Rollback(ctx) //nolint:errcheck

	result, rollback, err := fn(tx)
	if err != nil {
		return zero, err
	}
	if rollback {
		return result, nil
	}
	if err := tx.Commit(ctx); err != nil {
		// Commit gagal berarti kerja di dalam transaksi tidak tersimpan; hasil
		// yang dihitung di dalamnya tidak boleh dipakai pemanggil.
		return zero, fmt.Errorf("%w: %w", ErrTxCommit, err)
	}
	return result, nil
}

// isNoRows — singkatan yang dipakai beberapa pemanggil.
func isNoRows(err error) bool { return errors.Is(err, pgx.ErrNoRows) }
