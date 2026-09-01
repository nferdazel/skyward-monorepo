// Package db — koneksi pool Postgres (pgxpool) + tracer query lambat.
package db

import (
	"context"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// slowQueryThreshold — query lebih lambat dari ini di-log WARN.
const slowQueryThreshold = 200 * time.Millisecond

// NewPool membuat pool koneksi, verifikasi Ping, dan pasang slow query tracer.
func NewPool(ctx context.Context, databaseURL string, logger *slog.Logger) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, err
	}
	// Ukuran pool kecil — cukup untuk skala game solo/dev.
	cfg.MaxConns = 10
	cfg.MinConns = 1
	cfg.ConnConfig.Tracer = &slowQueryTracer{logger: logger, threshold: slowQueryThreshold}

	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	return pool, nil
}
