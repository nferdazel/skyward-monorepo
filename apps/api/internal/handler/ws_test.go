package handler

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestWSServerCheckOrigin(t *testing.T) {
	cases := []struct {
		name    string
		allowed []string
		origin  string
		want    bool
	}{
		{"non-browser tanpa Origin selalu boleh (dev/desktop)", []string{"https://skyward.qouver.com"}, "", true},
		{"allowlist kosong = dev lenient", nil, "https://evil.example", true},
		{"origin dalam allowlist", []string{"https://skyward.qouver.com"}, "https://skyward.qouver.com", true},
		{"port longgar utk host yg sama", []string{"http://localhost:5173"}, "http://localhost:9999", true},
		{"origin asing ditolak", []string{"https://skyward.qouver.com"}, "https://evil.example", false},
		{"subdomain asing ditolak", []string{"https://skyward.qouver.com"}, "https://qouver.com", false},
		{"origin ngasal (bukan URL) ditolak", []string{"https://skyward.qouver.com"}, "null", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := &WSServer{AllowedOrigins: tc.allowed}
			r := httptest.NewRequest(http.MethodGet, "/ws", nil)
			if tc.origin != "" {
				r.Header.Set("Origin", tc.origin)
			}
			if got := s.checkOrigin(r); got != tc.want {
				t.Fatalf("checkOrigin(%q) = %v, want %v", tc.origin, got, tc.want)
			}
		})
	}
}

func TestOriginHost(t *testing.T) {
	for in, want := range map[string]string{
		"https://Skyward.Qouver.com":  "skyward.qouver.com",
		"http://localhost:5173":       "localhost",
		"skyward.qouver.com":          "skyward.qouver.com",
		"https://skyward.qouver.com/": "skyward.qouver.com",
	} {
		if got := originHost(in); got != want {
			t.Fatalf("originHost(%q) = %q, want %q", in, got, want)
		}
	}
}
