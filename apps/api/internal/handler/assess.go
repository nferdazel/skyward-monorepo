package handler

import (
	"context"
	"errors"
	"net/http"
	"strconv"

	"skyward-api/internal/engine"
	"skyward-api/internal/httperr"
)

// routeAssessor — bagian engine yang dibutuhkan `GET /routes/assess`. Sempit
// dengan sengaja: handler read lain memakai `*store.Store`/`*engine.Engine`
// konkret sehingga tidak bisa diuji tanpa database, sedangkan endpoint ini
// cukup satu metode untuk diuji end-to-end dengan fake.
type routeAssessor interface {
	AssessRoute(ctx context.Context, userID string, p engine.AssessRouteParams) (*engine.AssessResult, error)
}

// RouteAssessHandler — diisi `*engine.Engine` oleh main.go.
type RouteAssessHandler struct {
	Assessor routeAssessor
}

// RouteAssess — GET /routes/assess. Menilai satu rute usulan memakai mesin yang
// sama dengan tick; klien tidak lagi menghitung ekonominya sendiri.
//
// Parameter lewat query string, bukan body: ini GET idempoten dan `ApiClient.get`
// di klien memang hanya mengirim query (`get(path, query: …)`).
func (h *RouteAssessHandler) RouteAssess(w http.ResponseWriter, r *http.Request) {
	uid, ok := userID(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	flights, err := strconv.Atoi(q.Get("flights_per_week"))
	if err != nil {
		httperr.WriteError(w, nil, httperr.Validation("flights_per_week must be an integer"))
		return
	}
	price, err := strconv.ParseFloat(q.Get("ticket_price"), 64)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Validation("ticket_price must be a number"))
		return
	}
	p := engine.AssessRouteParams{
		OriginIATA:      q.Get("origin_iata"),
		DestinationIATA: q.Get("destination_iata"),
		TicketPrice:     price,
		FlightsPerWeek:  flights,
		AircraftID:      q.Get("aircraft_id"),
	}
	res, err := h.Assessor.AssessRoute(r.Context(), uid, p)
	if err != nil {
		switch {
		case errors.Is(err, engine.ErrAssessInvalid):
			httperr.WriteError(w, nil, httperr.Validation("invalid route parameters"))
		case errors.Is(err, engine.ErrAssessAirportNotFound):
			httperr.WriteError(w, nil, httperr.NotFound("airport not found"))
		default:
			httperr.WriteError(w, nil, httperr.Internal("assess route failed"))
		}
		return
	}
	httperr.WriteJSON(w, http.StatusOK, res)
}
