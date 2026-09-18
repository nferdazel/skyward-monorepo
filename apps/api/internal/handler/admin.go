// Package handler — AdminGuard middleware (Authorization: Bearer <admin_token>).
package handler

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"skyward-api/internal/auth"
	"skyward-api/internal/httperr"
	"skyward-api/internal/store"
)

// AdminGuard — middleware untuk endpoint admin (ops: owner optimizer, world tick manual, dll).
// Memeriksa `Authorization: Bearer <token>` terhadap `SKYWARD_ADMIN_TOKEN`.
//
// AUDIT-03: fail-CLOSED. Config kosong dulu lolos di env dev (header `Bearer `
// kosong = authed). Sekarang token kosong ⇒ 503 di semua env. Perbandingan
// pakai constant-time compare.
func AdminGuard(token string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if token == "" {
			httperr.WriteError(w, nil, httperr.Unavailable("admin endpoints disabled (no SKYWARD_ADMIN_TOKEN)"))
			return
		}
		h := r.Header.Get("Authorization")
		if h == "" {
			httperr.WriteError(w, nil, httperr.Unauthorized("missing admin token"))
			return
		}
		parts := strings.SplitN(h, " ", 2)
		if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") ||
			subtle.ConstantTimeCompare([]byte(parts[1]), []byte(token)) != 1 {
			httperr.WriteError(w, nil, httperr.Unauthorized("invalid admin token"))
			return
		}
		next(w, r)
	}
}

// ResetPassword — POST /admin/account/{id}/reset-password {password}.
// Admin-only: set password baru untuk user (tanpa email).
//
// Query-nya memakai `store.UpdatePasswordHash`. Sebelumnya handler ini menulis
// UPDATE-nya sendiri, dan penggabungan `err != nil` dengan
// `RowsAffected() == 0` membuat error database sungguhan (mis. koneksi putus)
// dilaporkan sebagai 404 "user not found" — pemanggil akan mengira ID-nya
// salah dan mencoba lagi, bukan menelusuri masalah database.
func ResetPassword(st *store.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Password string `json:"password"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || len(body.Password) < 6 {
			httperr.WriteError(w, nil, httperr.Validation("password required (min 6 chars)"))
			return
		}
		hash, err := auth.HashPassword(body.Password)
		if err != nil {
			httperr.WriteError(w, nil, httperr.Internal("hash failed"))
			return
		}
		switch err := st.UpdatePasswordHash(r.Context(), r.PathValue("id"), hash); {
		case errors.Is(err, store.ErrUserNotFound):
			httperr.WriteError(w, nil, httperr.NotFound("user not found"))
			return
		case err != nil:
			httperr.WriteError(w, nil, httperr.Internal("reset password failed"))
			return
		}
		httperr.WriteJSON(w, http.StatusOK, map[string]bool{"success": true})
	}
}
