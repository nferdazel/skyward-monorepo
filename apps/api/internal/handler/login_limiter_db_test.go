package handler

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"skyward-api/internal/middleware"
	"skyward-api/internal/store"
	"skyward-api/internal/testsupport"
)

// TestLoginLimiterBlocksBruteForce — regresi 1.9b: /auth/login tidak punya
// pembatas per-username, sehingga password bisa ditebak tanpa batas (hanya
// dibatasi rate limit global per menit).
func TestLoginLimiterBlocksBruteForce(t *testing.T) {
	pool := testsupport.NewTestPool(t)
	testsupport.Reset(t, pool)

	user := testsupport.SeedUser(t, pool, "Brute Air", "CEO")
	if _, err := pool.Exec(t.Context(),
		`UPDATE users SET username=$1, password_hash='bogus' WHERE id=$2`, user, user); err != nil {
		t.Fatalf("seed username: %v", err)
	}

	h := &AuthHandler{
		Store:        store.New(pool),
		JWTSecret:    []byte("test-secret-at-least-32-bytes-long!!"),
		LoginLimiter: middleware.NewWindowLimiter(15*time.Minute, 0),
	}

	body := `{"username":"` + user + `","password":"wrong-password"}`
	attempt := func() *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/auth/login", strings.NewReader(body))
		w := httptest.NewRecorder()
		h.Login(w, req)
		return w
	}

	// 10 percobaan pertama: kredensial salah → 401 (bukan 429).
	for i := 1; i <= 10; i++ {
		if code := attempt().Code; code != http.StatusUnauthorized {
			t.Fatalf("attempt %d: status = %d, want 401", i, code)
		}
	}
	// Percobaan ke-11 harus diblokir.
	w := attempt()
	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("attempt 11: status = %d, want 429", w.Code)
	}
	var payload struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if payload.Error.Code != "too_many_requests" {
		t.Fatalf("code = %q, want too_many_requests", payload.Error.Code)
	}

	// Username lain tidak boleh ikut terblokir.
	other := `{"username":"someone-else","password":"x"}`
	req := httptest.NewRequest(http.MethodPost, "/auth/login", strings.NewReader(other))
	wOther := httptest.NewRecorder()
	h.Login(wOther, req)
	if wOther.Code == http.StatusTooManyRequests {
		t.Fatal("username lain ikut terblokir; limit harus per-username")
	}
}
