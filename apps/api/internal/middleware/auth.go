// Package middleware — AuthGuard (JWT) untuk endpoint game.
package middleware

import (
	"context"
	"net/http"
	"strings"

	"skyward-api/internal/auth"
	"skyward-api/internal/httperr"
)

type ctxKeyUserID struct{}

// UserIDFromContext — user_id (public.users.id) dari context, hasil AuthGuard.
func UserIDFromContext(ctx context.Context) (string, bool) {
	v, ok := ctx.Value(ctxKeyUserID{}).(string)
	return v, ok
}

// AuthGuard — validasi Authorization: Bearer <jwt>; resolve user_id ke context.
// Handler memakai UserIDFromContext untuk memanggil inner overload SQL
// (p_user_id) — menggantikan auth.uid() era Supabase.
func AuthGuard(secret []byte, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := bearerToken(r)
		if token == "" {
			httperr.WriteError(w, nil, httperr.Unauthorized("missing bearer token"))
			return
		}
		tok, err := auth.Parse(token, secret)
		if err != nil {
			httperr.WriteError(w, nil, httperr.Unauthorized("invalid token: "+err.Error()))
			return
		}
		if tok.Sub == "" {
			httperr.WriteError(w, nil, httperr.Unauthorized("token missing sub claim"))
			return
		}
		ctx := context.WithValue(r.Context(), ctxKeyUserID{}, tok.Sub)
		next(w, r.WithContext(ctx))
	}
}

// bearerToken — ekstrak token dari header Authorization.
func bearerToken(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if h == "" {
		return ""
	}
	parts := strings.SplitN(h, " ", 2)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
		return ""
	}
	return strings.TrimSpace(parts[1])
}
