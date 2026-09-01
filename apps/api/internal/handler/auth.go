// Package handler — auth handler (register/login/me).
//
// Fase 3: implementasi penuh.
// - register: argon2id hash → INSERT public.users (trigger bank account otomatis)
// - login: verifikasi argon2id → JWT sign
// - me: validasi JWT → query users
package handler

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"skyward-api/internal/auth"
	"skyward-api/internal/httperr"
	"skyward-api/internal/middleware"
	"skyward-api/internal/store"
)

// AuthHandler — register, login, me.
type AuthHandler struct {
	Store     *store.Store
	JWTSecret []byte
}

// userJSON — payload user yang dikembalikan ke client (tanpa password_hash).
type userJSON struct {
	ID                  string  `json:"id"`
	Username            string  `json:"username"`
	CompanyName         string  `json:"company_name"`
	CeoName             string  `json:"ceo_name"`
	GameCurrentTime     string  `json:"game_current_time"`
	NetWorth            float64 `json:"net_worth"`
	HQAirportIATA       *string `json:"hq_airport_iata"`
	AutoGroundingThresh float64 `json:"auto_grounding_threshold"`
	OperationalStatus   string  `json:"operational_status"`
	SeasonID            *string `json:"season_id"`
	OnboardingCompleted bool    `json:"onboarding_completed"`
}

func toUserJSON(u *store.User) userJSON {
	return userJSON{
		ID:                  u.ID,
		Username:            u.Username,
		CompanyName:         u.CompanyName,
		CeoName:             u.CeoName,
		GameCurrentTime:     u.GameCurrentTime.UTC().Format(time.RFC3339),
		NetWorth:            u.NetWorth,
		HQAirportIATA:       u.HQAirportIATA,
		AutoGroundingThresh: u.AutoGroundingThresh,
		OperationalStatus:   u.OperationalStatus,
		SeasonID:            u.SeasonID,
		OnboardingCompleted: u.OnboardingCompleted,
	}
}

type authResponse struct {
	Token string   `json:"token"`
	User  userJSON `json:"user"`
}

// Register — POST /auth/register {username, password, companyName, ceoName}.
func (h *AuthHandler) Register(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Username    string `json:"username"`
		Password    string `json:"password"`
		CompanyName string `json:"companyName"`
		CeoName     string `json:"ceoName"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		httperr.WriteError(w, nil, httperr.Validation("invalid request body"))
		return
	}

	// Validasi dasar
	if strings.TrimSpace(body.Username) == "" {
		httperr.WriteError(w, nil, httperr.Validation("username is required"))
		return
	}
	if len(body.Password) < 6 {
		httperr.WriteError(w, nil, httperr.Validation("password must be at least 6 characters"))
		return
	}
	if strings.TrimSpace(body.CompanyName) == "" {
		httperr.WriteError(w, nil, httperr.Validation("companyName is required"))
		return
	}
	if strings.TrimSpace(body.CeoName) == "" {
		httperr.WriteError(w, nil, httperr.Validation("ceoName is required"))
		return
	}

	// Normalisasi username (parity dengan fungsi SQL normalize_username)
	username, err := h.Store.NormalizeUsername(r.Context(), body.Username)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("normalize username failed"))
		return
	}
	if username == "" {
		httperr.WriteError(w, nil, httperr.Validation("username contains no valid characters"))
		return
	}

	hash, err := auth.HashPassword(body.Password)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("password hashing failed"))
		return
	}

	u, err := h.Store.CreateUser(r.Context(), &store.User{
		Username:     username,
		CompanyName:  strings.TrimSpace(body.CompanyName),
		CeoName:      strings.TrimSpace(body.CeoName),
		PasswordHash: &hash,
	})
	if err != nil {
		if err == store.ErrUsernameTaken {
			httperr.WriteError(w, nil, httperr.Validation("username or company name already taken"))
			return
		}
		httperr.WriteError(w, nil, httperr.Internal("register failed"))
		return
	}

	token, err := auth.Sign(auth.Claims{Sub: u.ID, Username: u.Username}, h.JWTSecret)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("token signing failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusCreated, authResponse{Token: token, User: toUserJSON(u)})
}

// Login — POST /auth/login {username, password}.
func (h *AuthHandler) Login(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		httperr.WriteError(w, nil, httperr.Validation("invalid request body"))
		return
	}

	u, err := h.Store.GetUserByUsername(r.Context(), strings.TrimSpace(body.Username))
	if err != nil {
		// Hindari user enumeration: response sama untuk user tak dikenal & password salah
		httperr.WriteError(w, nil, httperr.Unauthorized("invalid username or password"))
		return
	}
	if u.PasswordHash == nil || *u.PasswordHash == "" {
		httperr.WriteError(w, nil, httperr.Unauthorized("invalid username or password"))
		return
	}
	ok, err := auth.VerifyPassword(body.Password, *u.PasswordHash)
	if err != nil || !ok {
		httperr.WriteError(w, nil, httperr.Unauthorized("invalid username or password"))
		return
	}

	token, err := auth.Sign(auth.Claims{Sub: u.ID, Username: u.Username}, h.JWTSecret)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("token signing failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, authResponse{Token: token, User: toUserJSON(u)})
}

// Me — GET /auth/me (AuthGuard). Return user row.
func (h *AuthHandler) Me(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.UserIDFromContext(r.Context())
	if !ok || userID == "" {
		httperr.WriteError(w, nil, httperr.Unauthorized("not authenticated"))
		return
	}
	u, err := h.Store.GetUserByID(r.Context(), userID)
	if err != nil {
		if err == store.ErrUserNotFound {
			httperr.WriteError(w, nil, httperr.Unauthorized("account no longer exists"))
			return
		}
		httperr.WriteError(w, nil, httperr.Internal("load profile failed"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, toUserJSON(u))
}
