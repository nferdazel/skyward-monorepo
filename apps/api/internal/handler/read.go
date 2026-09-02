// Package handler — HTTP handlers read surface (Fase 4).
// Semua handler thin: resolve user_id dari context → panggil store → JSON.
package handler

import (
	"net/http"
	"strconv"

	"skyward-api/internal/httperr"
	"skyward-api/internal/middleware"
	"skyward-api/internal/store"
)

// ReadHandler — resource read handlers.
type ReadHandler struct {
	Store *store.Store
}

// userID — helper: user_id dari AuthGuard context, 401 bila tidak ada.
func userID(w http.ResponseWriter, r *http.Request) (string, bool) {
	uid, ok := middleware.UserIDFromContext(r.Context())
	if !ok || uid == "" {
		httperr.WriteError(w, nil, httperr.Unauthorized("not authenticated"))
		return "", false
	}
	return uid, true
}

// userID — helper: user_id dari AuthGuard context, 401 bila tidak ada.
func (h *ReadHandler) userID(w http.ResponseWriter, r *http.Request) (string, bool) {
	uid, ok := middleware.UserIDFromContext(r.Context())
	if !ok || uid == "" {
		httperr.WriteError(w, nil, httperr.Unauthorized("not authenticated"))
		return "", false
	}
	return uid, true
}

// ── Simulation ────────────────────────────────────────────────────────

func (h *ReadHandler) SimulationState(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	st, err := h.Store.GetSimulationState(r.Context(), uid)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("load simulation state failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, st)
}

func (h *ReadHandler) GameConfig(w http.ResponseWriter, r *http.Request) {
	cfg, err := h.Store.GetGameConfig(r.Context())
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("load game config failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, cfg)
}

// ── Fleet ─────────────────────────────────────────────────────────────

func (h *ReadHandler) Fleet(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	fleet, err := h.Store.GetFleet(r.Context(), uid)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("load fleet failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, fleet)
}

func (h *ReadHandler) AircraftModels(w http.ResponseWriter, r *http.Request) {
	models, err := h.Store.GetAircraftModels(r.Context())
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("load catalog failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, models)
}

// ── Routes ────────────────────────────────────────────────────────────

func (h *ReadHandler) Routes(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	routes, err := h.Store.GetRoutes(r.Context(), uid)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("load routes failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, routes)
}

func (h *ReadHandler) Airports(w http.ResponseWriter, r *http.Request) {
	ap, err := h.Store.GetAirports(r.Context())
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("load airports failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, ap)
}

// ── Finance ───────────────────────────────────────────────────────────

func (h *ReadHandler) FinanceSnapshot(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	f, err := h.Store.GetFinanceSnapshot(r.Context(), uid)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("load finance snapshot failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, f)
}

func (h *ReadHandler) FinanceTransactions(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	txns, err := h.Store.GetBankTransactions(r.Context(), uid, limit, offset)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("load transactions failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, txns)
}

// ── Leaderboard ───────────────────────────────────────────────────────

func (h *ReadHandler) Leaderboard(w http.ResponseWriter, r *http.Request) {
	lb, err := h.Store.GetLeaderboard(r.Context())
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("load leaderboard failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, lb)
}

func (h *ReadHandler) CompetitorInsights(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if id == "" {
		httperr.WriteError(w, nil, httperr.Validation("competitor id required"))
		return
	}
	isBot := r.URL.Query().Get("isBot") == "true"
	ci, err := h.Store.GetCompetitorInsights(r.Context(), id, isBot)
	if err != nil {
		httperr.WriteError(w, nil, httperr.NotFound("competitor not found"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, ci)
}

// ── Bank ──────────────────────────────────────────────────────────────

func (h *ReadHandler) BankLoans(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	loans, err := h.Store.GetLoans(r.Context(), uid)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("load loans failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, loans)
}

func (h *ReadHandler) BankCredit(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	cr, err := h.Store.GetCreditReport(r.Context(), uid)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("load credit report failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, cr)
}

// ── Extra reads (Fase 9 pendukung gateway) ────────────────────────────

func (h *ReadHandler) FleetAvailable(w http.ResponseWriter, r *http.Request) {
	uid, ok := h.userID(w, r)
	if !ok {
		return
	}
	list, err := h.Store.GetFleetAvailable(r.Context(), uid)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("load available fleet failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, list)
}

func (h *ReadHandler) FleetByID(w http.ResponseWriter, r *http.Request) {
	uid, ok := h.userID(w, r)
	if !ok {
		return
	}
	f, err := h.Store.GetFleetByID(r.Context(), uid, r.PathValue("id"))
	if err != nil {
		httperr.WriteError(w, nil, httperr.NotFound("aircraft not found"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, f)
}

func (h *ReadHandler) FleetLatestForModel(w http.ResponseWriter, r *http.Request) {
	uid, ok := h.userID(w, r)
	if !ok {
		return
	}
	f, err := h.Store.GetLatestFleetForModel(r.Context(), uid, r.PathValue("modelId"))
	if err != nil {
		httperr.WriteError(w, nil, httperr.NotFound("no aircraft for model"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, f)
}

func (h *ReadHandler) GroundingThreshold(w http.ResponseWriter, r *http.Request) {
	uid, ok := h.userID(w, r)
	if !ok {
		return
	}
	t, err := h.Store.GetGroundingThreshold(r.Context(), uid)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("load threshold failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, map[string]float64{"auto_grounding_threshold": t})
}

func (h *ReadHandler) FinanceHistory(w http.ResponseWriter, r *http.Request) {
	uid, ok := h.userID(w, r)
	if !ok {
		return
	}
	snap, err := h.Store.GetFinanceSnapshots(r.Context(), uid, 60)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("load finance history failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, snap)
}

func (h *ReadHandler) BankCreditHistory(w http.ResponseWriter, r *http.Request) {
	uid, ok := h.userID(w, r)
	if !ok {
		return
	}
	hist, err := h.Store.GetCreditHistory(r.Context(), uid, 60)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("load credit history failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, hist)
}

func (h *ReadHandler) BankAccounts(w http.ResponseWriter, r *http.Request) {
	uid, ok := h.userID(w, r)
	if !ok {
		return
	}
	accs, err := h.Store.GetBankAccounts(r.Context(), uid)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("load bank accounts failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, accs)
}

func (h *ReadHandler) BankTransactionsByAccount(w http.ResponseWriter, r *http.Request) {
	accountID := r.URL.Query().Get("accountId")
	if accountID == "" {
		h.FinanceTransactions(w, r)
		return
	}
	txns, err := h.Store.GetBankTransactionsByAccount(r.Context(), accountID, 50)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("load account transactions failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, txns)
}
