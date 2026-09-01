// Package store — akses data (queries langsung ke tabel) + transaksi.
//
// Engine memakai store untuk membaca/menulis data. Semua mutasi engine
// berjalan dalam satu transaksi (store.Tx). Tidak ada fungsi SQL yang dipanggil.
package store

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Store — akses DB untuk engine & handler.
type Store struct {
	pool *pgxpool.Pool
}

// New — buat Store.
func New(pool *pgxpool.Pool) *Store { return &Store{pool: pool} }

// Pool — akses pool langsung (untuk handler read yang tidak perlu engine).
func (s *Store) Pool() *pgxpool.Pool { return s.pool }

// Tx — jalankan fn dalam satu transaksi.
// Rollback otomatis bila fn return error. Commit bila sukses.
func (s *Store) Tx(ctx context.Context, fn func(context.Context, pgx.Tx) error) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin tx: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if err := fn(ctx, tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
