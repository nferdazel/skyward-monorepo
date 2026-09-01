// Package store — akses data untuk auth & user.
package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// ErrUsernameTaken — unique violation username/company_name (SQLSTATE 23505).
var ErrUsernameTaken = errors.New("username already taken")

// ErrUserNotFound — tidak ada user dengan identifier tsb.
var ErrUserNotFound = errors.New("user not found")

// User — baris public.users (sebagian field; expand sesuai kebutuhan).
type User struct {
	ID                  string
	Username            string
	CompanyName         string
	CeoName             string
	GameCurrentTime     time.Time
	NetWorth            float64
	HQAirportIATA       *string
	AutoGroundingThresh float64
	OperationalStatus   string
	SeasonID            *string
	PasswordHash        *string
	OnboardingCompleted bool
}

// ActiveSeason — baris season_clock aktif.
type ActiveSeason struct {
	ID              string
	CurrentGameTime time.Time
	TimeScale       float64
	TickIntervalSec int
}

// GetActiveSeason — season dengan status='active' (partial unique index → max 1).
func (s *Store) GetActiveSeason(ctx context.Context) (*ActiveSeason, error) {
	var out ActiveSeason
	err := s.pool.QueryRow(ctx,
		`SELECT id, current_game_time, time_scale_multiplier, tick_interval_seconds
		   FROM season_clock WHERE status = 'active' LIMIT 1`,
	).Scan(&out.ID, &out.CurrentGameTime, &out.TimeScale, &out.TickIntervalSec)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrUserNotFound // reuse: "belum ada season"
	}
	if err != nil {
		return nil, fmt.Errorf("store: get active season: %w", err)
	}
	return &out, nil
}

// CreateUser — INSERT users; trigger create_default_bank_account menciptakan
// bank_accounts (starting_cash dari game_config) secara otomatis.
// username/companyName harus sudah dinormalisasi. Mengembalikan row lengkap.
func (s *Store) CreateUser(ctx context.Context, u *User) (*User, error) {
	season, err := s.GetActiveSeason(ctx)
	if err != nil {
		return nil, fmt.Errorf("store: register butuh season aktif: %w", err)
	}
	row := s.pool.QueryRow(ctx,
		`INSERT INTO users
		   (username, company_name, ceo_name, password_hash, hq_airport_iata,
		    game_current_time, season_id, actor_type, operational_status)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, 'REAL', 'Active')
		 RETURNING id, username, company_name, ceo_name, game_current_time,
		           net_worth, hq_airport_iata, auto_grounding_threshold,
		           operational_status, season_id, password_hash, onboarding_completed`,
		u.Username, u.CompanyName, u.CeoName, u.PasswordHash, u.HQAirportIATA,
		season.CurrentGameTime, season.ID,
	)
	out := &User{}
	err = row.Scan(
		&out.ID, &out.Username, &out.CompanyName, &out.CeoName,
		&out.GameCurrentTime, &out.NetWorth, &out.HQAirportIATA,
		&out.AutoGroundingThresh, &out.OperationalStatus, &out.SeasonID,
		&out.PasswordHash, &out.OnboardingCompleted,
	)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, ErrUsernameTaken
		}
		return nil, fmt.Errorf("store: create user: %w", err)
	}
	return out, nil
}

// GetUserByUsername — cari user berdasarkan username (untuk login).
func (s *Store) GetUserByUsername(ctx context.Context, username string) (*User, error) {
	return s.scanUser(ctx,
		`SELECT id, username, company_name, ceo_name, game_current_time,
		        net_worth, hq_airport_iata, auto_grounding_threshold,
		        operational_status, season_id, password_hash, onboarding_completed
		   FROM users WHERE username = $1`, username)
}

// GetUserByID — cari user berdasarkan id (untuk /auth/me).
func (s *Store) GetUserByID(ctx context.Context, id string) (*User, error) {
	return s.scanUser(ctx,
		`SELECT id, username, company_name, ceo_name, game_current_time,
		        net_worth, hq_airport_iata, auto_grounding_threshold,
		        operational_status, season_id, password_hash, onboarding_completed
		   FROM users WHERE id = $1`, id)
}

func (s *Store) scanUser(ctx context.Context, q string, arg any) (*User, error) {
	u := &User{}
	err := s.pool.QueryRow(ctx, q, arg).Scan(
		&u.ID, &u.Username, &u.CompanyName, &u.CeoName,
		&u.GameCurrentTime, &u.NetWorth, &u.HQAirportIATA,
		&u.AutoGroundingThresh, &u.OperationalStatus, &u.SeasonID,
		&u.PasswordHash, &u.OnboardingCompleted,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrUserNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("store: scan user: %w", err)
	}
	return u, nil
}

// NormalizeUsername — normalisasi username via fungsi SQL (parity dengan
// konstrain unik & fungsi lama).
func (s *Store) NormalizeUsername(ctx context.Context, username string) (string, error) {
	var out *string
	err := s.pool.QueryRow(ctx,
		`SELECT public.normalize_username($1)`, username).Scan(&out)
	if err != nil {
		return "", fmt.Errorf("store: normalize username: %w", err)
	}
	if out == nil {
		return "", nil
	}
	return *out, nil
}
