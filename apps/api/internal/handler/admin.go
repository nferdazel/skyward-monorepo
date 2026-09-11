// Package handler — AdminGuard middleware (Authorization: Bearer <admin_token>).
package handler

import (
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"strings"

	"skyward-api/internal/auth"
	"skyward-api/internal/httperr"

	"github.com/jackc/pgx/v5/pgxpool"
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
func ResetPassword(pool *pgxpool.Pool) http.HandlerFunc {
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
		tag, err := pool.Exec(r.Context(), `UPDATE users SET password_hash=$1 WHERE id=$2`, hash, r.PathValue("id"))
		if err != nil || tag.RowsAffected() == 0 {
			httperr.WriteError(w, nil, httperr.NotFound("user not found"))
			return
		}
		httperr.WriteJSON(w, http.StatusOK, map[string]bool{"success": true})
	}
}
