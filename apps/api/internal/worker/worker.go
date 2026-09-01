// Package worker — world-tick worker loop (menggantikan pg_cron).
//
// Worker memanggil ensure_world_current() + prune + finance_snapshots
// dalam goroutine terpisah. Quadlet menjamin single instance per container.
// ID:  This file is part of skyward-api.
package worker

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Status — status worker untuk endpoint /admin/worker/status.
type Status struct {
	Alive         bool   `json:"alive"`
	LastTickAt    string `json:"last_tick_at,omitempty"`
	LastTickMs    int64  `json:"last_tick_ms,omitempty"`
	ErrorsCount   int    `json:"errors_count"`
	NextTickAfter string `json:"next_tick_after,omitempty"`
	Status        string `json:"status"`
}

// Worker — world-tick + prune loop.
type Worker struct {
	pool    *pgxpool.Pool
	tickFn  func(context.Context) error
	logger  *slog.Logger
	enabled bool
	// interval default (fallback); nilai sebenarnya dari season_clock.tick_interval_seconds
	interval time.Duration
	status   *Status
	mu       sync.RWMutex
	done     chan struct{}
}

// New — buat Worker. Belum jalan sampai Start() dipanggil.
func New(pool *pgxpool.Pool, tickFn func(context.Context) error, logger *slog.Logger, enabled bool, intervalSec int) *Worker {
	return &Worker{
		pool:     pool,
		tickFn:   tickFn,
		logger:   logger,
		enabled:  enabled,
		interval: time.Duration(intervalSec) * time.Second,
		status:   &Status{Alive: false, Status: "initialized"},
		done:     make(chan struct{}),
	}
}

// Start — jalankan loop di goroutine. Non-blocking.
func (w *Worker) Start(ctx context.Context) {
	if !w.enabled {
		w.logger.Info("worker disabled, not starting")
		return
	}
	go w.loop(ctx)
}

// Stop — sinyal loop berhenti (blok sampai goroutine berhenti).
func (w *Worker) Stop() {
	select {
	case <-w.done:
	default:
		close(w.done)
	}
}

// Alive — apakah worker hidup dan tidak dalam error state.
func (w *Worker) Alive() bool {
	w.mu.RLock()
	defer w.mu.RUnlock()
	if w.status == nil {
		return false
	}
	return w.status.Alive
}

// Status — copy status saat ini.
func (w *Worker) Status() Status {
	w.mu.RLock()
	defer w.mu.RUnlock()
	if w.status == nil {
		return Status{}
	}
	return *w.status
}

// backoff — kapasitas backoff exponensial.
func backoff(n int) time.Duration {
	d := 1
	for range n {
		d *= 2
		if d > 60 {
			d = 60
			break
		}
	}
	return time.Duration(d) * time.Second
}

func (w *Worker) loop(ctx context.Context) {
	w.logger.Info("worker started", "interval", w.interval)
	w.mu.Lock()
	w.status.Alive = true
	w.status.Status = "running"
	w.mu.Unlock()

	ticker := time.NewTicker(w.interval)
	defer ticker.Stop()
	errors := 0
	for {
		select {
		case <-ctx.Done():
			w.mu.Lock()
			w.status.Status = "stopped"
			w.status.Alive = false
			w.mu.Unlock()
			w.logger.Info("worker stopped")
			return
		case <-w.done:
			w.mu.Lock()
			w.status.Status = "stopped"
			w.status.Alive = false
			w.mu.Unlock()
			w.logger.Info("worker stopped (signal)")
			return
		case <-ticker.C:
			if err := w.runTick(ctx); err != nil {
				errors++
				w.mu.Lock()
				w.status.ErrorsCount = errors
				w.mu.Unlock()
				w.logger.Error("tick failed", "error", err, "errors_total", errors)
				// backoff on error
				ticker.Reset(backoff(errors))
				continue
			}
			errors = 0
			w.mu.Lock()
			w.status.ErrorsCount = 0
			w.mu.Unlock()
			// TODO Fase 6: baca season_clock.tick_interval_seconds dan reset
			// ticker.Interval bila berubah.
		}
	}
}

func (w *Worker) runTick(ctx context.Context) error {
	start := time.Now()
	if w.tickFn == nil {
		return nil
	}
	if err := w.tickFn(ctx); err != nil {
		return err
	}
	elapsed := time.Since(start)
	w.mu.Lock()
	w.status.LastTickAt = time.Now().UTC().Format(time.RFC3339)
	w.status.LastTickMs = elapsed.Milliseconds()
	w.mu.Unlock()
	w.logger.Info("tick selesai", "duration_ms", elapsed.Milliseconds())
	return nil
}
