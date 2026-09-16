package handler

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"skyward-api/internal/auth"
	"skyward-api/internal/engine"
	"skyward-api/internal/middleware"
)

// fakeAssessor — fake `routeAssessor`, jadi handler bisa diuji tanpa database.
type fakeAssessor struct {
	gotUser   string
	gotParams engine.AssessRouteParams
	result    *engine.AssessResult
	err       error
	calls     int

	batchResult []engine.AssessResult
	batchErr    error
	batchCalls  int
}

func (f *fakeAssessor) AssessRoute(_ context.Context, userID string, p engine.AssessRouteParams) (*engine.AssessResult, error) {
	f.calls++
	f.gotUser = userID
	f.gotParams = p
	return f.result, f.err
}

func (f *fakeAssessor) AssessPlayerRoutes(_ context.Context, userID string) ([]engine.AssessResult, error) {
	f.batchCalls++
	f.gotUser = userID
	return f.batchResult, f.batchErr
}

func assessTestServer(t *testing.T, f *fakeAssessor) (http.HandlerFunc, string) {
	t.Helper()
	secret := []byte("test-secret-at-least-32-bytes-long!!")
	token, err := auth.Sign(auth.Claims{Sub: "user-1", Username: "u"}, secret)
	if err != nil {
		t.Fatalf("sign token: %v", err)
	}
	h := &RouteAssessHandler{Assessor: f}
	return middleware.AuthGuard(secret, h.RouteAssess), token
}

func assessBatchTestServer(t *testing.T, f *fakeAssessor) (http.HandlerFunc, string) {
	t.Helper()
	secret := []byte("test-secret-at-least-32-bytes-long!!")
	token, err := auth.Sign(auth.Claims{Sub: "user-1", Username: "u"}, secret)
	if err != nil {
		t.Fatalf("sign token: %v", err)
	}
	h := &RouteAssessHandler{Assessor: f}
	return middleware.AuthGuard(secret, h.RouteAssessBatch), token
}

func batchRequest(token string) *http.Request {
	req := httptest.NewRequest(http.MethodGet, "/routes/assess/batch", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	return req
}

func assessRequest(token, query string) *http.Request {
	req := httptest.NewRequest(http.MethodGet, "/routes/assess?"+query, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	return req
}

// TestRouteAssessRejectsWithoutToken — endpoint read, wajib di balik AuthGuard.
func TestRouteAssessRejectsWithoutToken(t *testing.T) {
	f := &fakeAssessor{}
	guarded, _ := assessTestServer(t, f)

	w := httptest.NewRecorder()
	guarded(w, httptest.NewRequest(http.MethodGet, "/routes/assess", nil))

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", w.Code)
	}
	if f.calls != 0 {
		t.Fatalf("assessor dipanggil %d kali tanpa token, want 0", f.calls)
	}
}

// TestRouteAssessRejectsMalformedQuery — angka yang tidak bisa di-parse ditolak
// sebelum menyentuh engine.
func TestRouteAssessRejectsMalformedQuery(t *testing.T) {
	f := &fakeAssessor{}
	guarded, token := assessTestServer(t, f)

	for _, q := range []string{"flights_per_week=abc", "ticket_price=xx"} {
		w := httptest.NewRecorder()
		guarded(w, assessRequest(token, "origin_iata=CGK&destination_iata=DPS&"+q))

		if w.Code != http.StatusBadRequest {
			t.Fatalf("%s: status = %d, want 400", q, w.Code)
		}
	}
	if f.calls != 0 {
		t.Fatalf("assessor dipanggil %d kali dengan query rusak, want 0", f.calls)
	}
}

// TestRouteAssessMapsSentinelErrors — salah parameter 400, bandara tak dikenal 404.
func TestRouteAssessMapsSentinelErrors(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want int
	}{
		{"parameter tidak valid", engine.ErrAssessInvalid, http.StatusBadRequest},
		{"bandara tidak ada", engine.ErrAssessAirportNotFound, http.StatusNotFound},
		{"error lain", context.DeadlineExceeded, http.StatusInternalServerError},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := &fakeAssessor{err: c.err}
			guarded, token := assessTestServer(t, f)

			w := httptest.NewRecorder()
			guarded(w, assessRequest(token, "origin_iata=CGK&destination_iata=DPS&ticket_price=100&flights_per_week=7"))

			if w.Code != c.want {
				t.Fatalf("status = %d, want %d", w.Code, c.want)
			}
		})
	}
}

// TestRouteAssessSuccess — parameter diteruskan apa adanya dan hasilnya JSON 200.
func TestRouteAssessSuccess(t *testing.T) {
	f := &fakeAssessor{result: &engine.AssessResult{
		Origin:                "CGK",
		Destination:           "DPS",
		DistanceKM:            1234.5,
		HasCompatibleAircraft: true,
		Aircraft: []engine.RouteAssessment{{
			AircraftID:    "ac-1",
			AircraftModel: "Testjet",
			Viability:     engine.AssessViability{Band: "strong"},
		}},
	}}
	guarded, token := assessTestServer(t, f)

	w := httptest.NewRecorder()
	guarded(w, assessRequest(token, "origin_iata=CGK&destination_iata=DPS&ticket_price=150.5&flights_per_week=14&aircraft_id=ac-1"))

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body: %s)", w.Code, w.Body.String())
	}
	if f.gotUser != "user-1" {
		t.Errorf("user id = %q, want user-1", f.gotUser)
	}
	if f.gotParams.OriginIATA != "CGK" || f.gotParams.DestinationIATA != "DPS" ||
		f.gotParams.TicketPrice != 150.5 || f.gotParams.FlightsPerWeek != 14 || f.gotParams.AircraftID != "ac-1" {
		t.Errorf("parameter tidak diteruskan utuh: %+v", f.gotParams)
	}

	var body engine.AssessResult
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if !body.HasCompatibleAircraft || len(body.Aircraft) != 1 || body.Aircraft[0].Viability.Band != "strong" {
		t.Errorf("response = %+v", body)
	}
}

// TestRouteAssessBatchRejectsWithoutToken — endpoint read, wajib di balik AuthGuard.
func TestRouteAssessBatchRejectsWithoutToken(t *testing.T) {
	f := &fakeAssessor{}
	guarded, _ := assessBatchTestServer(t, f)

	w := httptest.NewRecorder()
	guarded(w, httptest.NewRequest(http.MethodGet, "/routes/assess/batch", nil))

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", w.Code)
	}
	if f.batchCalls != 0 {
		t.Fatalf("assessor dipanggil %d kali tanpa token, want 0", f.batchCalls)
	}
}

// TestRouteAssessBatchSuccess — daftar rute dibungkus `routes` dan hasilnya JSON.
func TestRouteAssessBatchSuccess(t *testing.T) {
	f := &fakeAssessor{batchResult: []engine.AssessResult{
		{
			RouteID:               "route-1",
			Origin:                "CGK",
			Destination:           "DOH",
			HasCompatibleAircraft: true,
			Aircraft: []engine.RouteAssessment{{
				AircraftID:    "ac-1",
				AircraftModel: "A321neo",
				Viability:     engine.AssessViability{Band: "weak"},
			}},
		},
		{RouteID: "route-2", Origin: "CGK", Destination: "SYD"},
	}}
	guarded, token := assessBatchTestServer(t, f)

	w := httptest.NewRecorder()
	guarded(w, batchRequest(token))

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body: %s)", w.Code, w.Body.String())
	}
	if f.gotUser != "user-1" {
		t.Errorf("user id = %q, want user-1", f.gotUser)
	}
	var body struct {
		Routes []engine.AssessResult `json:"routes"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body.Routes) != 2 {
		t.Fatalf("routes = %d, want 2", len(body.Routes))
	}
	if body.Routes[0].RouteID != "route-1" || !body.Routes[0].HasCompatibleAircraft {
		t.Errorf("route pertama = %+v", body.Routes[0])
	}
}

// TestRouteAssessBatchEmptyIsArrayNotNull — pemain tanpa rute mengembalikan [].
func TestRouteAssessBatchEmptyIsArrayNotNull(t *testing.T) {
	f := &fakeAssessor{}
	guarded, token := assessBatchTestServer(t, f)

	w := httptest.NewRecorder()
	guarded(w, batchRequest(token))

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}
	// WriteJSON menutup dengan newline, jadi bandingkan setelah di-trim.
	if got := strings.TrimSpace(w.Body.String()); got != `{"routes":[]}` {
		t.Errorf("body = %s, want {\"routes\":[]}", got)
	}
}

// TestRouteAssessBatchMapsInternalError — kegagalan engine jadi 500, bukan 200 kosong.
func TestRouteAssessBatchMapsInternalError(t *testing.T) {
	f := &fakeAssessor{batchErr: context.DeadlineExceeded}
	guarded, token := assessBatchTestServer(t, f)

	w := httptest.NewRecorder()
	guarded(w, batchRequest(token))

	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", w.Code)
	}
}
