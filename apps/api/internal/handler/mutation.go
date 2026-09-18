// Package handler — mutation handlers (Fase 5): fleet, routes, settings, bank.
package handler

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"skyward-api/internal/engine"
	"skyward-api/internal/httperr"
	"skyward-api/internal/store"
)

// MutationHandler — mutations, thin: AuthGuard → engine → JSON.
type MutationHandler struct {
	Engine *engine.Engine
	Hub    engine.Broadcaster
	// Store dipakai untuk query yang bukan bagian dari engine, misalnya membaca
	// season aktif dan menandai onboarding. Sebelumnya handler menulis SQL itu
	// sendiri lewat `Engine.Pool`, yang membuat lapisan handler tahu bentuk
	// skema dan melewati store.
	Store *store.Store
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

// decodeBody — baca body JSON ke `dst`, tulis 400 kalau gagal.
//
// Sembilan handler mengulang blok decode yang sama dengan pesan validasi yang
// sama. Blok `if !ok { return }` tetap ditulis pemanggil karena helper tidak
// bisa mengembalikan dari fungsi pemanggil; yang dihapus adalah pengulangan
// pembacaan body dan penulisan galatnya.
func decodeBody(w http.ResponseWriter, r *http.Request, dst any) bool {
	if err := json.NewDecoder(r.Body).Decode(dst); err != nil {
		httperr.WriteError(w, nil, httperr.Validation("invalid request body"))
		return false
	}
	return true
}

// runMutation — jalankan satu mutasi engine lalu kirim hasilnya.
//
// Dua belas handler mengulang urutan yang sama persis: panggil engine, kalau
// error tulis 500 dengan pesan yang spesifik untuk handler itu, lalu
// `respondChannel`. Yang tetap berbeda per handler adalah pesan errornya, jadi
// pesan itu tetap ditulis di pemanggil.
//
// Empat handler bank SENGAJA tidak memakai ini: mereka memakai
// `httperr.Wrap` supaya cause-nya ikut terkirim (lihat catatan di
// BankTakeLoan), dan itu bukan bentuk yang sama.
func (h *MutationHandler) runMutation(
	w http.ResponseWriter,
	res *engine.MutationResult,
	err error,
	failureMessage, channel, event string,
) {
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal(failureMessage))
		return
	}
	h.respondChannel(w, res, channel, event)
}

// ── Fleet ─────────────────────────────────────────────────────────────

func (h *MutationHandler) FleetPurchase(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	var p engine.PurchaseParams
	if !decodeBody(w, r, &p) {
		return
	}
	res, err := h.Engine.Fleet.Purchase(r.Context(), uid, p)
	h.runMutation(w, res, err, "fleet purchase failed", "fleet_aircraft", "INSERT")
}

func (h *MutationHandler) FleetSell(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	res, err := h.Engine.Fleet.Sell(r.Context(), uid, r.PathValue("id"))
	h.runMutation(w, res, err, "fleet sell failed", "fleet_aircraft", "DELETE")
}

func (h *MutationHandler) FleetRepair(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	res, err := h.Engine.Fleet.Repair(r.Context(), uid, r.PathValue("id"))
	h.runMutation(w, res, err, "fleet repair failed", "fleet_aircraft", "UPDATE")
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
	if !decodeBody(w, r, &p) {
		return
	}
	res, err := h.Engine.Fleet.ConfigureSeats(r.Context(), uid, r.PathValue("id"), p.EconomySeats, p.BusinessSeats, p.FirstClassSeats)
	h.runMutation(w, res, err, "configure seats failed", "fleet_aircraft", "UPDATE")
}

// ── Routes ────────────────────────────────────────────────────────────

func (h *MutationHandler) RouteCreate(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	var p engine.CreateRouteParams
	if !decodeBody(w, r, &p) {
		return
	}
	res, err := h.Engine.Routes.Create(r.Context(), uid, p)
	h.runMutation(w, res, err, "create route failed", "route_assignments", "INSERT")
}

func (h *MutationHandler) RouteDelete(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	res, err := h.Engine.Routes.Delete(r.Context(), uid, r.PathValue("id"))
	h.runMutation(w, res, err, "delete route failed", "route_assignments", "DELETE")
}

// ── Settings ──────────────────────────────────────────────────────────

func (h *MutationHandler) SettingsSave(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	var p engine.SaveParams
	if !decodeBody(w, r, &p) {
		return
	}
	res, err := h.Engine.Settings.Save(r.Context(), uid, p)
	h.runMutation(w, res, err, "save settings failed", "users", "UPDATE")
}

func (h *MutationHandler) SettingsReset(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	res, err := h.Engine.Settings.Reset(r.Context(), uid)
	h.runMutation(w, res, err, "reset settings failed", "users", "UPDATE")
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
	if !decodeBody(w, r, &p) {
		return
	}
	res, err := h.Engine.Bank.TakeLoan(r.Context(), uid, p)
	if err != nil {
		// Cause ikut dikirim: sejak 1.8b body 500 selalu generik, jadi tanpa ini
		// penyebab kegagalan infra tidak terlihat di mana pun.
		httperr.WriteError(w, nil, httperr.Wrap(httperr.CodeInternal, "take loan failed", err))
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
	// Body kosong tetap berarti "lunasi seluruh pinjaman" (Amount nil), tetapi
	// JSON yang rusak tidak boleh diperlakukan sama: dulu error decode dibuang,
	// sehingga body rusak menghasilkan pelunasan penuh alih-alih 400.
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil && !errors.Is(err, io.EOF) {
		httperr.WriteError(w, nil, httperr.Validation("invalid request body"))
		return
	}
	res, err := h.Engine.Bank.Repay(r.Context(), uid, r.PathValue("id"), p.Amount)
	if err != nil {
		// Cause ikut dikirim: sejak 1.8b body 500 selalu generik, jadi tanpa ini
		// penyebab kegagalan infra tidak terlihat di mana pun.
		httperr.WriteError(w, nil, httperr.Wrap(httperr.CodeInternal, "repay loan failed", err))
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
	if !decodeBody(w, r, &p) {
		return
	}
	res, err := h.Engine.Fleet.Lease(r.Context(), uid, p)
	h.runMutation(w, res, err, "lease aircraft failed", "fleet_aircraft", "INSERT")
}

func (h *MutationHandler) FleetTerminateLease(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	res, err := h.Engine.Fleet.TerminateLease(r.Context(), uid, r.PathValue("id"))
	h.runMutation(w, res, err, "terminate lease failed", "fleet_aircraft", "DELETE")
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
	if !decodeBody(w, r, &p) {
		return
	}
	res, err := h.Engine.Routes.Assign(r.Context(), uid, r.PathValue("id"), p.AircraftID)
	h.runMutation(w, res, err, "route assign failed", "route_assignments", "UPDATE")
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
	if !decodeBody(w, r, &p) {
		return
	}
	res, err := h.Engine.Routes.UpdateFreqPrice(r.Context(), uid, r.PathValue("id"), p.TicketPrice, p.FlightsPerWeek)
	h.runMutation(w, res, err, "update route failed", "route_assignments", "UPDATE")
}

// ── Bank (lanjutan) ───────────────────────────────────────────────────

func (h *MutationHandler) BankRefinanceLoan(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	res, err := h.Engine.Bank.Refinance(r.Context(), uid, r.PathValue("id"))
	if err != nil {
		// Cause ikut dikirim: sejak 1.8b body 500 selalu generik, jadi tanpa ini
		// penyebab kegagalan infra tidak terlihat di mana pun.
		httperr.WriteError(w, nil, httperr.Wrap(httperr.CodeInternal, "refinance loan failed", err))
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
	if !decodeBody(w, r, &p) {
		return
	}
	res, err := h.Engine.Bank.FinanceAircraft(r.Context(), uid, p)
	if err != nil {
		// Cause ikut dikirim: sejak 1.8b body 500 selalu generik, jadi tanpa ini
		// penyebab kegagalan infra tidak terlihat di mana pun.
		httperr.WriteError(w, nil, httperr.Wrap(httperr.CodeInternal, "finance aircraft failed", err))
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
	seasonTime, err := h.Store.GetActiveSeasonTime(r.Context())
	if err != nil {
		// AUDIT-13: jangan pernah lapor success kalau tidak ada season aktif.
		httperr.WriteError(w, nil, httperr.Internal("no active season for simulation sync"))
		return
	}
	// nil: jalur sync satu-pemain memuat snapshot-nya sendiri (1 query config +
	// 1 query event, bukan 16 + 2 per rute).
	result, err := h.Engine.ProcessPlayer(r.Context(), uid, seasonTime, nil)
	if err != nil {
		// AUDIT-06: sync gagal = 500; clock player tidak maju, client retry aman.
		httperr.WriteError(w, nil, httperr.Internal("simulation sync failed"))
		return
	}
	// Deliver any achievements unlocked since the last sync (including those
	// inserted by the background world tick). Claimed here, not in the engine,
	// so the tick never consumes a toast it cannot show.
	newlyUnlocked := h.Engine.ClaimUnnotifiedAchievements(r.Context(), uid)
	httperr.WriteJSON(w, http.StatusOK, map[string]any{
		"success":                     true,
		"message":                     "simulation synced",
		"elapsed_game_days":           result.ElapsedDays,
		"flights_run":                 result.FlightsRun,
		"revenue":                     result.Revenue,
		"expense":                     result.Expense,
		"newly_unlocked_achievements": newlyUnlocked,
	})
}

// SimulationOnboarding — POST /simulation/onboarding: tandai onboarding selesai.
func (h *MutationHandler) SimulationOnboarding(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	if err := h.Store.MarkOnboardingComplete(r.Context(), uid); err != nil {
		httperr.WriteError(w, nil, httperr.Internal("mark onboarding failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, map[string]bool{"success": true})
}
