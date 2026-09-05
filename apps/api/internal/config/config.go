// Package config — konfigurasi runtime dari environment; `.env` di-load
// untuk dev lokal, prod memakai systemd env (file 600).
//
// Pola mengikuti majadu-api: fail-closed (default prod), secret hanya di VPS.
// Path database ada di DATABASE_URL, search_path default `public`
// (baseline skyward ada di public). Instansi VPS dev sudah dihapus (2026-09-05).
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/joho/godotenv"
)

// Config — runtime configuration.
type Config struct {
	// Env — "dev" | "prod". Dev = lenient (default fallback), prod = strict.
	Env string

	// Port HTTP server. Default 8090.
	Port string

	// Host HTTP server binding address. Default "127.0.0.1".
	Host string

	// DatabaseURL — postgres://... WAJIB (fail-fast).
	// Prod: postgres://skyward_app:...@qouver-postgres:5432/skyward
	DatabaseURL string

	// AllowedOrigins — origin CORS frontend (Caddy static / localhost dev).
	AllowedOrigins []string

	// BaseURL — URL publik API (header Location), mis.
	// https://api.qouver.com/skyward. Kosong = relative path.
	BaseURL string

	// RateLimitPerMin — batas request per menit per IP. 0 = disabled.
	RateLimitPerMin int

	// LogDir — direktori log harian (app-YYYY-MM-DD.log, retensi 7 hari).
	// Kosong = log ke stdout (default dev).
	LogDir string

	// LogLevel — "debug" | "info" | "warn" | "error". Default info.
	LogLevel string

	// AdminToken — token admin (Authorization: Bearer) untuk endpoint ops
	// (owner optimizer, world tick manual, worker status). Wajib di prod.
	AdminToken string

	// JWTSecret — secret HS256 untuk token game. Wajib di prod (min 32 byte).
	JWTSecret string

	// WorkerEnabled — aktifkan world-tick worker loop di proses ini.
	// Default true. Bisa dimatikan untuk smoke test terisolasi.
	WorkerEnabled bool

	// WorkerTickIntervalSeconds — interval loop worker (default 60).
	// Nilai sebenarnya dibaca dari game_config di DB; ini fallback startup.
	WorkerTickIntervalSeconds int
}

// Load membaca env, me-load .env jika ada, lalu validasi.
// Prod gagal cepat (exit) kalau config wajib tidak ada.
func Load() (Config, error) {
	// .env hanya untuk dev lokal — error diabaikan (file mungkin tidak ada).
	_ = godotenv.Load()

	cfg := Config{
		Env:                       getenv("SKYWARD_ENV", "prod"),
		Port:                      getenv("PORT", "8090"),
		Host:                      getenv("HOST", "127.0.0.1"),
		RateLimitPerMin:           atoiDefault(os.Getenv("SKYWARD_RATE_LIMIT_PER_MIN"), 2400),
		LogDir:                    os.Getenv("SKYWARD_LOG_DIR"),
		LogLevel:                  os.Getenv("SKYWARD_LOG_LEVEL"),
		AdminToken:                os.Getenv("SKYWARD_ADMIN_TOKEN"),
		JWTSecret:                 os.Getenv("SKYWARD_JWT_SECRET"),
		WorkerEnabled:             boolDefault(os.Getenv("SKYWARD_WORKER_ENABLED"), true),
		WorkerTickIntervalSeconds: atoiDefault(os.Getenv("SKYWARD_WORKER_TICK_INTERVAL_SECONDS"), 60),
	}

	cfg.DatabaseURL = os.Getenv("DATABASE_URL")
	if cfg.DatabaseURL == "" {
		return cfg, fmt.Errorf("DATABASE_URL is required")
	}
	cfg.BaseURL = strings.TrimRight(os.Getenv("PUBLIC_BASE_URL"), "/")
	for _, origin := range splitList(os.Getenv("CORS_ALLOWED_ORIGINS")) {
		cfg.AllowedOrigins = append(cfg.AllowedOrigins, origin)
	}

	if err := cfg.validate(); err != nil {
		return cfg, err
	}
	return cfg, nil
}

func (c Config) validate() error {
	if c.Env != "dev" && c.Env != "prod" {
		return fmt.Errorf("SKYWARD_ENV must be 'dev' or 'prod', got %q", c.Env)
	}
	if c.Port == "" {
		return fmt.Errorf("PORT must not be empty")
	}
	if c.Env == "prod" {
		if len(c.AllowedOrigins) == 0 {
			return fmt.Errorf("CORS_ALLOWED_ORIGINS is required in prod")
		}
		if c.AdminToken == "" {
			return fmt.Errorf("SKYWARD_ADMIN_TOKEN is required in prod")
		}
		if len(c.JWTSecret) < 32 {
			return fmt.Errorf("SKYWARD_JWT_SECRET is required in prod (min 32 chars)")
		}
	}
	return nil
}

// getenv — ambil env key; kosong/absent → fallback.
func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// splitList — pecah string comma-separated, buang bagian kosong.
func splitList(s string) []string {
	var out []string
	for _, part := range strings.Split(s, ",") {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

// atoiDefault — parse int; string kosong/invalid/negatif → fallback.
func atoiDefault(s string, fallback int) int {
	if s == "" {
		return fallback
	}
	n, err := strconv.Atoi(s)
	if err != nil || n < 0 {
		return fallback
	}
	return n
}

// boolDefault — parse boolean; string kosong/invalid → fallback.
func boolDefault(s string, fallback bool) bool {
	if s == "" {
		return fallback
	}
	b, err := strconv.ParseBool(s)
	if err != nil {
		return fallback
	}
	return b
}
