// skyward-api — backend Go untuk game Skyward (menggantikan Supabase/PostgREST).
//
// Arsitektur: Postgres tetap otoritas ekonomi (114 fungsi SQL). Go = gerbang
// akses (REST + WS) + auth (JWT) + world-tick worker. Lihat grand-revamp-plan.md
// (repo skyward, gitignored) untuk desain & fase eksekusi.
package main

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"skyward-api/internal/build"
	"skyward-api/internal/config"
	"skyward-api/internal/db"
	"skyward-api/internal/engine"
	"skyward-api/internal/handler"
	"skyward-api/internal/httperr"
	"skyward-api/internal/logfile"
	"skyward-api/internal/middleware"
	"skyward-api/internal/realtime"
	"skyward-api/internal/store"
	"skyward-api/internal/worker"

	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	// Fail-fast: prod harus punya config lengkap.
	cfg, err := config.Load()
	if err != nil {
		slog.Error("config error", "error", err)
		os.Exit(1)
	}

	// Logger: stdout default; kalau SKYWARD_LOG_DIR di-set → file harian
	// (app-YYYY-MM-DD.log, retensi 7 hari).
	var logCloser func() error
	var logOut io.Writer = os.Stdout
	if cfg.LogDir != "" {
		w, err := logfile.New(cfg.LogDir, 7)
		if err != nil {
			slog.Error("log file init failed", "error", err)
			os.Exit(1)
		}
		logOut = w
		logCloser = w.Close
	}
	logger := slog.New(slog.NewTextHandler(logOut, &slog.HandlerOptions{
		Level: parseLogLevel(cfg.LogLevel),
	}))
	if logCloser != nil {
		defer func() { _ = logCloser() }()
	}

	// Context dibatalkan saat SIGINT/SIGTERM.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, err := db.NewPool(ctx, cfg.DatabaseURL, logger)
	if err != nil {
		logger.Error("database connection failed", "error", err)
		os.Exit(1)
	}
	defer pool.Close()
	logger.Info("database connected")
	// World-tick worker (Fase 6: engine.WorldTick; loop + backoff).
	st := store.New(pool)
	eng := engine.New(pool, st)
	hub := realtime.NewHub(logger)
	eng.Hub = hub
	wk := worker.New(pool, func(ctx context.Context) error {
		_, err := eng.WorldTick(ctx)
		return err
	}, logger, cfg.WorkerEnabled, cfg.WorkerTickIntervalSeconds)
	wk.Start(ctx)
	defer wk.Stop()

	mux := http.NewServeMux()
	registerRoutes(ctx, mux, logger, cfg, pool, st, wk, hub)

	// Middleware chain: recover (luar) → request-id → logging → CORS → rate limit → mux.
	var h http.Handler = mux
	h = middleware.RateLimit(ctx, cfg.RateLimitPerMin, logger)(h)
	h = middleware.CORS(cfg.AllowedOrigins)(h)
	h = middleware.Logging(logger)(h)
	h = middleware.RequestID(h)
	h = middleware.Recover(logger)(h)

	srv := &http.Server{
		Addr:         cfg.Host + ":" + cfg.Port,
		Handler:      h,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		logger.Info("server listening", "addr", srv.Addr, "env", cfg.Env,
			"version", build.Version, "commit", build.Commit)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("server error", "error", err)
			os.Exit(1)
		}
	}()

	// Graceful shutdown.
	<-ctx.Done()
	logger.Info("shutting down...")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("shutdown error", "error", err)
	}
}

// registerRoutes — routing REST + middleware chain.
func registerRoutes(ctx context.Context, mux *http.ServeMux, logger *slog.Logger, cfg config.Config, pool *pgxpool.Pool, st *store.Store, wk *worker.Worker, hub *realtime.Hub) {
	health := &handler.HealthHandler{Pool: pool, Worker: wk}
	mux.Handle("GET /healthz", http.HandlerFunc(health.Healthz))
	mux.Handle("GET /health", http.HandlerFunc(health.Healthz))
	mux.Handle("GET /readyz", http.HandlerFunc(health.Ready))
	mux.Handle("GET /version", http.HandlerFunc(health.Version))

	// Auth (Fase 3 — register/login/me).
	// Realtime WS (Fase 8) — token via query param.
	wsServer := &handler.WSServer{Hub: hub, JWTSecret: []byte(cfg.JWTSecret)}
	mux.Handle("GET /ws", http.HandlerFunc(wsServer.ServeWS))

	authHandler := &handler.AuthHandler{Store: st, JWTSecret: []byte(cfg.JWTSecret)}
	mux.Handle("POST /auth/register", http.HandlerFunc(authHandler.Register))
	mux.Handle("POST /auth/login", http.HandlerFunc(authHandler.Login))
	mux.Handle("GET /auth/me", middleware.AuthGuard([]byte(cfg.JWTSecret), authHandler.Me))

	// Read surface (Fase 4) — semua di balik AuthGuard.
	read := &handler.ReadHandler{Store: st}
	guard := func(next http.HandlerFunc) http.HandlerFunc {
		return middleware.AuthGuard([]byte(cfg.JWTSecret), next)
	}
	mux.Handle("GET /simulation/state", guard(read.SimulationState))
	mux.Handle("GET /game-config", guard(read.GameConfig))
	mux.Handle("GET /fleet", guard(read.Fleet))
	mux.Handle("GET /aircraft-models", guard(read.AircraftModels))
	mux.Handle("GET /routes", guard(read.Routes))
	mux.Handle("GET /airports", guard(read.Airports))
	mux.Handle("GET /finance/snapshot", guard(read.FinanceSnapshot))
	mux.Handle("GET /finance/transactions", guard(read.FinanceTransactions))
	mux.Handle("GET /leaderboard", guard(read.Leaderboard))
	mux.Handle("GET /leaderboard/competitors/{id}", guard(read.CompetitorInsights))
	mux.Handle("GET /bank/credit", guard(read.BankCredit))
	mux.Handle("GET /bank/loans", guard(read.BankLoans))

	// Mutasi (Fase 5) — fleet/routes/settings/bank writes.
	eng := engine.New(pool, st)
	mut := &handler.MutationHandler{Engine: eng, Hub: hub}
	mux.Handle("POST /fleet/purchase", guard(mut.FleetPurchase))
	mux.Handle("POST /fleet/lease", guard(mut.FleetLease))
	mux.Handle("POST /fleet/{id}/sell", guard(mut.FleetSell))
	mux.Handle("POST /fleet/{id}/repair", guard(mut.FleetRepair))
	mux.Handle("POST /fleet/{id}/terminate-lease", guard(mut.FleetTerminateLease))
	mux.Handle("PATCH /fleet/{id}/seats", guard(mut.FleetConfigureSeats))
	mux.Handle("POST /routes", guard(mut.RouteCreate))
	mux.Handle("POST /routes/{id}/assign", guard(mut.RouteAssign))
	mux.Handle("PATCH /routes/{id}", guard(mut.RouteUpdateFreqPrice))
	mux.Handle("DELETE /routes/{id}", guard(mut.RouteDelete))
	mux.Handle("PATCH /settings", guard(mut.SettingsSave))
	mux.Handle("POST /settings/reset", guard(mut.SettingsReset))
	mux.Handle("DELETE /account", guard(mut.AccountDelete))
	mux.Handle("POST /bank/loans", guard(mut.BankTakeLoan))
	mux.Handle("POST /bank/loans/{id}/repay", guard(mut.BankRepayLoan))
	mux.Handle("POST /bank/loans/{id}/refinance", guard(mut.BankRefinanceLoan))
	mux.Handle("POST /bank/finance-aircraft", guard(mut.BankFinanceAircraft))

	mux.Handle("POST /simulation/sync", guard(mut.SimulationSync))
	mux.Handle("POST /simulation/onboarding", guard(mut.SimulationOnboarding))
	mux.Handle("GET /fleet/available", guard(read.FleetAvailable))
	mux.Handle("GET /fleet/{id}", guard(read.FleetByID))
	mux.Handle("GET /fleet/models/{modelId}/latest", guard(read.FleetLatestForModel))
	mux.Handle("GET /settings/grounding-threshold", guard(read.GroundingThreshold))
	mux.Handle("GET /finance/history", guard(read.FinanceHistory))
	mux.Handle("GET /bank/credit/history", guard(read.BankCreditHistory))
	mux.Handle("GET /bank/accounts", guard(read.BankAccounts))
	mux.Handle("GET /bank/transactions", guard(read.BankTransactionsByAccount))

	// Admin / ops (AdminGuard).
	admin := func(next http.HandlerFunc) http.HandlerFunc {
		return handler.AdminGuard(cfg.AdminToken, next)
	}
	mux.Handle("POST /admin/account/{id}/reset-password", admin(handler.ResetPassword(pool)))
	mux.Handle("GET /admin/worker/status", admin(func(w http.ResponseWriter, r *http.Request) {
		httperr.WriteJSON(w, http.StatusOK, wk.Status())
	}))
	mux.Handle("POST /admin/world/tick", admin(func(w http.ResponseWriter, r *http.Request) {
		result, err := eng.WorldTick(r.Context())
		if err != nil {
			httperr.WriteError(w, nil, httperr.Internal("tick failed: "+err.Error()))
			return
		}
		httperr.WriteJSON(w, http.StatusOK, result)
	}))
	// TODO Fase 5+: /admin/owner/route-optimizer, /admin/world/guardrail-report,
	// /admin/world/scheduler-health, POST /admin/world/tick, /admin/account/{id}/reset-password
}

// parseLogLevel — map SKYWARD_LOG_LEVEL ke slog.Level.
func parseLogLevel(s string) slog.Level {
	switch s {
	case "debug":
		return slog.LevelDebug
	case "warn":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
