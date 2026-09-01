// Package handler — health/liveness/readiness endpoints.
package handler

import (
	"context"
	"net/http"
	"time"

	"skyward-api/internal/build"
	"skyward-api/internal/httperr"
	"skyward-api/internal/worker"

	"github.com/jackc/pgx/v5/pgxpool"
)

// HealthHandler — /healthz (liveness) & /readyz (readiness, cek DB + worker).
type HealthHandler struct {
	Pool   *pgxpool.Pool
	Worker *worker.Worker
}

func (h *HealthHandler) Healthz(w http.ResponseWriter, _ *http.Request) {
	httperr.WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (h *HealthHandler) Ready(w http.ResponseWriter, r *http.Request) {
	if h.Pool == nil {
		httperr.WriteError(w, nil, httperr.Unavailable("database not configured"))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := h.Pool.Ping(ctx); err != nil {
		httperr.WriteError(w, nil, httperr.Unavailable("database unreachable"))
		return
	}
	if h.Worker != nil && !h.Worker.Alive() {
		httperr.WriteError(w, nil, httperr.Unavailable("world tick worker not alive"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (h *HealthHandler) Version(w http.ResponseWriter, _ *http.Request) {
	httperr.WriteJSON(w, http.StatusOK, map[string]string{
		"version": build.Version,
		"commit":  build.Commit,
		"date":    build.Date,
	})
}
