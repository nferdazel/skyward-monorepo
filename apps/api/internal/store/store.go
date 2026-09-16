// Package store — akses data (queries langsung ke tabel).
//
// Engine memakai store untuk membaca/menulis data. Semua mutasi engine berjalan
// dalam transaksi eksplisit yang dibuka engine sendiri (`Pool.Begin`); tidak ada
// fungsi SQL (RPC era Supabase) yang dipanggil.
package store

import (
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
