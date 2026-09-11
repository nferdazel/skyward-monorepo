package handler

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestAdminGuard(t *testing.T) {
	ok := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })

	cases := []struct {
		name       string
		configTok  string
		authHeader string
		want       int
	}{
		{"fail-closed: config token kosong, header kosong", "", "", 503},
		{"fail-closed: config token kosong, 'Bearer ' kosong pun DITOLAK", "", "Bearer ", 503},
		{"missing header", "s3cret", "", 401},
		{"wrong scheme", "s3cret", "Basic s3cret", 401},
		{"wrong token", "s3cret", "Bearer wrong", 401},
		{"correct token", "s3cret", "Bearer s3cret", 200},
		{"scheme case-insensitive", "s3cret", "bearer s3cret", 200},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/admin/world/tick", nil)
			if tc.authHeader != "" {
				req.Header.Set("Authorization", tc.authHeader)
			}
			rec := httptest.NewRecorder()
			AdminGuard(tc.configTok, ok)(rec, req)
			if rec.Code != tc.want {
				t.Fatalf("configToken=%q header=%q: got %d, want %d (body %s)",
					tc.configTok, tc.authHeader, rec.Code, tc.want, rec.Body.String())
			}
		})
	}
}
