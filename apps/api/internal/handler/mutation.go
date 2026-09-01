// Package handler — mutation handlers (Fase 5): fleet, routes, settings, bank.
package handler

import (
	"encoding/json"
	"net/http"
	"time"

	"skyward-api/internal/engine"
	"skyward-api/internal/httperr"
)

// MutationHandler — mutations, thin: AuthGuard → engine → JSON.
type MutationHandler struct {
	Engine *engine.Engine
	Hub    engine.Broadcaster
}

// broadcastOnSuccess — realtime notification setelah mutasi sukses.
func (h *MutationHandler) broadcastOnSuccess(channel, event string, res *engine.MutationResult) {
	if res != nil && res.Success && h.Hub != nil {
		h.Hub.Broadcast(channel, event)
	}
}

func (h *MutationHandler) respond(w http.ResponseWriter, res *engine.MutationResult) {
	h.respondChannel(w, res, "", "")
}

func (h *MutationHandler) respondChannel(w http.ResponseWriter, res *engine.MutationResult, channel, event string) {
	if res == nil {
		httperr.WriteError(w, nil, httperr.Internal("mutation failed"))
		return
	}
	if res.Success {
		h.broadcastOnSuccess(channel, event, res)
	}
	status := http.StatusOK
	if !res.Success {
		status = http.StatusBadRequest
	}
	httperr.WriteJSON(w, status, res)
}

// ── Fleet ─────────────────────────────────────────────────────────────

func (h *MutationHandler) FleetPurchase(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	var p engine.PurchaseParams
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		httperr.WriteError(w, nil, httperr.Validation("invalid request body"))
		return
	}
	res, err := h.Engine.Fleet.Purchase(r.Context(), uid, p)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("fleet purchase failed"))
		return
	}
	h.respondChannel(w, res, "fleet_aircraft", "INSERT")
}

func (h *MutationHandler) FleetSell(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	res, err := h.Engine.Fleet.Sell(r.Context(), uid, r.PathValue("id"))
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("fleet sell failed"))
		return
	}
	h.respondChannel(w, res, "fleet_aircraft", "DELETE")
}

func (h *MutationHandler) FleetRepair(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	res, err := h.Engine.Fleet.Repair(r.Context(), uid, r.PathValue("id"))
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("fleet repair failed"))
		return
	}
	h.respondChannel(w, res, "fleet_aircraft", "UPDATE")
}

func (h *MutationHandler) FleetConfigureSeats(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	var p struct {
		EconomySeats    int `json:"economy_seats"`
		BusinessSeats   int `json:"business_seats"`
		FirstClassSeats int `json:"first_class_seats"`
	}
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		httperr.WriteError(w, nil, httperr.Validation("invalid request body"))
		return
	}
	res, err := h.Engine.Fleet.ConfigureSeats(r.Context(), uid, r.PathValue("id"), p.EconomySeats, p.BusinessSeats, p.FirstClassSeats)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("configure seats failed"))
		return
	}
	h.respondChannel(w, res, "fleet_aircraft", "UPDATE")
}

// ── Routes ────────────────────────────────────────────────────────────

func (h *MutationHandler) RouteCreate(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	var p engine.CreateRouteParams
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		httperr.WriteError(w, nil, httperr.Validation("invalid request body"))
		return
	}
	res, err := h.Engine.Routes.Create(r.Context(), uid, p)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("create route failed"))
		return
	}
	h.respondChannel(w, res, "route_assignments", "INSERT")
}

func (h *MutationHandler) RouteDelete(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	res, err := h.Engine.Routes.Delete(r.Context(), uid, r.PathValue("id"))
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("delete route failed"))
		return
	}
	h.respondChannel(w, res, "route_assignments", "DELETE")
}

// ── Settings ──────────────────────────────────────────────────────────

func (h *MutationHandler) SettingsSave(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	var p engine.SaveParams
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		httperr.WriteError(w, nil, httperr.Validation("invalid request body"))
		return
	}
	res, err := h.Engine.Settings.Save(r.Context(), uid, p)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("save settings failed"))
		return
	}
	h.respondChannel(w, res, "users", "UPDATE")
}

func (h *MutationHandler) SettingsReset(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	res, err := h.Engine.Settings.Reset(r.Context(), uid)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("reset settings failed"))
		return
	}
	h.respondChannel(w, res, "users", "UPDATE")
}

func (h *MutationHandler) AccountDelete(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	ok, err := h.Engine.Settings.DeleteAccount(r.Context(), uid)
	if err != nil || !ok {
		httperr.WriteError(w, nil, httperr.Internal("delete account failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, map[string]bool{"success": true})
}

// ── Bank ──────────────────────────────────────────────────────────────

func (h *MutationHandler) BankTakeLoan(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	var p engine.TakeLoanParams
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		httperr.WriteError(w, nil, httperr.Validation("invalid request body"))
		return
	}
	res, err := h.Engine.Bank.TakeLoan(r.Context(), uid, p)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("take loan failed"))
		return
	}
	h.respondChannel(w, res, "loans", "INSERT")
}

func (h *MutationHandler) BankRepayLoan(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	var p struct {
		Amount *float64 `json:"amount,omitempty"`
	}
	_ = json.NewDecoder(r.Body).Decode(&p)
	res, err := h.Engine.Bank.Repay(r.Context(), uid, r.PathValue("id"), p.Amount)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("repay loan failed"))
		return
	}
	h.respondChannel(w, res, "loans", "UPDATE")
}

// ── Fleet (lanjutan) ──────────────────────────────────────────────────

func (h *MutationHandler) FleetLease(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	var p engine.LeaseParams
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		httperr.WriteError(w, nil, httperr.Validation("invalid request body"))
		return
	}
	res, err := h.Engine.Fleet.Lease(r.Context(), uid, p)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("lease aircraft failed"))
		return
	}
	h.respondChannel(w, res, "fleet_aircraft", "INSERT")
}

func (h *MutationHandler) FleetTerminateLease(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	res, err := h.Engine.Fleet.TerminateLease(r.Context(), uid, r.PathValue("id"))
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("terminate lease failed"))
		return
	}
	h.respondChannel(w, res, "fleet_aircraft", "DELETE")
}

// ── Routes (lanjutan) ─────────────────────────────────────────────────

func (h *MutationHandler) RouteAssign(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	var p struct {
		AircraftID string `json:"aircraft_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		httperr.WriteError(w, nil, httperr.Validation("invalid request body"))
		return
	}
	res, err := h.Engine.Routes.Assign(r.Context(), uid, r.PathValue("id"), p.AircraftID)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("route assign failed"))
		return
	}
	h.respondChannel(w, res, "route_assignments", "UPDATE")
}

func (h *MutationHandler) RouteUpdateFreqPrice(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	var p struct {
		TicketPrice    float64 `json:"ticket_price"`
		FlightsPerWeek int     `json:"flights_per_week"`
	}
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		httperr.WriteError(w, nil, httperr.Validation("invalid request body"))
		return
	}
	res, err := h.Engine.Routes.UpdateFreqPrice(r.Context(), uid, r.PathValue("id"), p.TicketPrice, p.FlightsPerWeek)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("update route failed"))
		return
	}
	h.respondChannel(w, res, "route_assignments", "UPDATE")
}

// ── Bank (lanjutan) ───────────────────────────────────────────────────

func (h *MutationHandler) BankRefinanceLoan(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	res, err := h.Engine.Bank.Refinance(r.Context(), uid, r.PathValue("id"))
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("refinance loan failed"))
		return
	}
	h.respondChannel(w, res, "loans", "UPDATE")
}

func (h *MutationHandler) BankFinanceAircraft(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	var p engine.FinanceAircraftParams
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		httperr.WriteError(w, nil, httperr.Validation("invalid request body"))
		return
	}
	res, err := h.Engine.Bank.FinanceAircraft(r.Context(), uid, p)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("finance aircraft failed"))
		return
	}
	h.respondChannel(w, res, "loans", "INSERT")
}

// ── Simulation sync & onboarding ───────────────────────────────────────

// SimulationSync — POST /simulation/sync: proses player ke season clock.
func (h *MutationHandler) SimulationSync(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	var seasonTime time.Time
	h.Engine.Pool.QueryRow(r.Context(),
		`SELECT current_game_time FROM season_clock WHERE status='active' LIMIT 1`).Scan(&seasonTime)
	h.Engine.ProcessPlayer(r.Context(), uid, seasonTime)
	httperr.WriteJSON(w, http.StatusOK, map[string]any{
		"success": true,
		"message": "simulation synced",
	})
}

// SimulationOnboarding — POST /simulation/onboarding: tandai onboarding selesai.
func (h *MutationHandler) SimulationOnboarding(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	_, err := h.Engine.Pool.Exec(r.Context(),
		`UPDATE users SET onboarding_completed=true WHERE id=$1`, uid)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("mark onboarding failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, map[string]bool{"success": true})
}
