package handler

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"skyward-api/internal/auth"
	"skyward-api/internal/middleware"
	"skyward-api/internal/realtime"
)

// wsServerForTicket — server dengan store sungguhan; tidak butuh Hub karena
// tes ini tidak pernah sampai ke upgrade.
func wsServerForTicket() (*WSServer, []byte) {
	secret := []byte("0123456789012345678901234567890123456789")
	return &WSServer{Tickets: realtime.NewTicketStore(), JWTSecret: secret}, secret
}

// TestTicketIssuedBehindAuthGuard — /ws/ticket wajib JWT di header, sama
// seperti endpoint REST lain. Ini satu-satunya langkah yang memakai JWT
// sekarang; handshake-nya memakai tiket.
func TestTicketIssuedBehindAuthGuard(t *testing.T) {
	s, secret := wsServerForTicket()
	token, err := auth.Sign(auth.Claims{Sub: "user-1", Username: "u"}, secret)
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodPost, "/ws/ticket", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()

	middleware.AuthGuard(secret, s.Ticket)(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, mau 200 (body: %s)", rec.Code, rec.Body.String())
	}
	var body struct {
		Ticket    string `json:"ticket"`
		ExpiresIn int    `json:"expires_in"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("body bukan JSON: %v", err)
	}
	if body.Ticket == "" {
		t.Fatal("tiket kosong")
	}
	if body.ExpiresIn != int(realtime.TicketTTL().Seconds()) {
		t.Fatalf("expires_in = %d, mau %d", body.ExpiresIn, int(realtime.TicketTTL().Seconds()))
	}
}

func TestTicketRejectedWithoutToken(t *testing.T) {
	s, secret := wsServerForTicket()
	req := httptest.NewRequest(http.MethodPost, "/ws/ticket", nil)
	rec := httptest.NewRecorder()

	middleware.AuthGuard(secret, s.Ticket)(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, mau 401 tanpa token", rec.Code)
	}
}

// Tiket dari /ws/ticket harus bisa ditukar di /ws — inilah kontrak antara
// kedua endpoint, dan satu-satunya alasan keduanya berbagi store.
func TestTicketRedeemableAtHandshake(t *testing.T) {
	s, secret := wsServerForTicket()
	token, _ := auth.Sign(auth.Claims{Sub: "user-1", Username: "u"}, secret)

	req := httptest.NewRequest(http.MethodPost, "/ws/ticket", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	middleware.AuthGuard(secret, s.Ticket)(rec, req)

	var body struct {
		Ticket string `json:"ticket"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}

	userID, ok := s.Tickets.Redeem(body.Ticket)
	if !ok {
		t.Fatal("tiket dari handler harus bisa ditukar")
	}
	if userID != "user-1" {
		t.Fatalf("user_id = %q, mau user-1", userID)
	}
}

// Handshake tanpa tiket, dengan tiket palsu, dan dengan tiket yang sudah
// dipakai harus sama-sama 401. Tidak ada JWT di jalur ini lagi.
func TestServeWSRejectsWithoutValidTicket(t *testing.T) {
	s, _ := wsServerForTicket()

	cases := []struct {
		name  string
		query string
	}{
		{"tanpa tiket", "/ws"},
		{"tiket kosong", "/ws?ticket="},
		{"tiket palsu", "/ws?ticket=tidak-pernah-diterbitkan"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, tc.query, nil)
			rec := httptest.NewRecorder()
			s.ServeWS(rec, req)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("status = %d, mau 401", rec.Code)
			}
		})
	}
}

// Tiket sekali pakai: percobaan kedua dengan tiket yang sama ditolak.
func TestServeWSRejectsReusedTicket(t *testing.T) {
	s, _ := wsServerForTicket()
	tok, err := s.Tickets.Issue("user-1")
	if err != nil {
		t.Fatal(err)
	}

	// Pakai tiketnya lewat handshake. Tanpa koneksi WS sungguhan upgrade-nya
	// gagal (bukan 401), tapi tiketnya sudah habis — itu yang diuji.
	req := httptest.NewRequest(http.MethodGet, "/ws?ticket="+tok, nil)
	rec := httptest.NewRecorder()
	s.ServeWS(rec, req)
	if rec.Code == http.StatusUnauthorized {
		t.Fatalf("tiket valid tidak boleh ditolak sebagai 401 (body: %s)", rec.Body.String())
	}

	req2 := httptest.NewRequest(http.MethodGet, "/ws?ticket="+tok, nil)
	rec2 := httptest.NewRecorder()
	s.ServeWS(rec2, req2)
	if rec2.Code != http.StatusUnauthorized {
		t.Fatalf("pemakaian ulang tiket harus 401, dapat %d", rec2.Code)
	}
}

// Query param lama `token` tidak lagi diterima — kalau ini lolos, JWT masih
// bisa dipakai lewat URL dan item D3 tidak benar-benar selesai.
func TestServeWSIgnoresLegacyTokenParam(t *testing.T) {
	s, secret := wsServerForTicket()
	jwt, _ := auth.Sign(auth.Claims{Sub: "user-1", Username: "u"}, secret)

	req := httptest.NewRequest(http.MethodGet, "/ws?token="+jwt, nil)
	rec := httptest.NewRecorder()
	s.ServeWS(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("JWT lewat query string harus ditolak, dapat %d", rec.Code)
	}
}
