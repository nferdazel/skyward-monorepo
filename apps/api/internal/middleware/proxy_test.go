package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func reqFrom(remoteAddr string, headers map[string]string) *http.Request {
	r := httptest.NewRequest(http.MethodGet, "/x", nil)
	r.RemoteAddr = remoteAddr
	for k, v := range headers {
		r.Header.Set(k, v)
	}
	return r
}

func TestClientIPTrustBoundary(t *testing.T) {
	t.Cleanup(func() { _ = SetTrustedProxies("") }) // restore default loopback

	// 1. Untrusted remote (langsung ke port API): header DIABAIKAN.
	got := clientIP(reqFrom("203.0.113.7:5555", map[string]string{
		"X-Forwarded-For":   "198.51.100.1",
		"CF-Connecting-IP":  "198.51.100.2",
		"X-Real-IP":         "198.51.100.3",
	}))
	if got != "203.0.113.7" {
		t.Fatalf("untrusted spoof headers must be ignored, got %q", got)
	}

	// 2. Trusted (loopback = Caddy di host yang sama): XFF pertama dipakai.
	got = clientIP(reqFrom("127.0.0.1:40404", map[string]string{
		"X-Forwarded-For": "198.51.100.9, 10.0.0.1",
	}))
	if got != "198.51.100.9" {
		t.Fatalf("trusted proxy XFF should win, got %q", got)
	}

	// 3. Trusted + CF header prioritas.
	got = clientIP(reqFrom("[::1]:1234", map[string]string{
		"CF-Connecting-IP": "203.0.113.5",
		"X-Forwarded-For":  "198.51.100.9",
	}))
	if got != "203.0.113.5" {
		t.Fatalf("CF header should win over XFF, got %q", got)
	}

	// 4. Trusted tapi header bukan IP valid → fallback socket IP.
	got = clientIP(reqFrom("127.0.0.1:9", map[string]string{"X-Forwarded-For": "not-an-ip"}))
	if got != "127.0.0.1" {
		t.Fatalf("invalid XFF should fall back to socket IP, got %q", got)
	}
}

func TestSetTrustedProxies(t *testing.T) {
	t.Cleanup(func() { _ = SetTrustedProxies("") })

	if err := SetTrustedProxies("10.0.0.0/8, 192.168.5.5"); err != nil {
		t.Fatal(err)
	}
	// CIDR baru dipercaya...
	got := clientIP(reqFrom("10.1.2.3:80", map[string]string{"X-Forwarded-For": "8.8.8.8"}))
	if got != "8.8.8.8" {
		t.Fatalf("10.0.0.0/8 should be trusted now, got %q", got)
	}
	// ...loopback default TIDAK lagi (di-overwrite penuh).
	got = clientIP(reqFrom("127.0.0.1:80", map[string]string{"X-Forwarded-For": "8.8.8.8"}))
	if got != "127.0.0.1" {
		t.Fatalf("loopback should no longer be trusted after override, got %q", got)
	}

	if err := SetTrustedProxies("bogus"); err == nil {
		t.Fatal("expected error for invalid CIDR")
	}
	if err := SetTrustedProxies(",,"); err == nil {
		t.Fatal("expected error for empty effective list")
	}
}
