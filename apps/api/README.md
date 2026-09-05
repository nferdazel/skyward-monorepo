# skyward-api

Backend Go untuk game **Skyward** — menggantikan Supabase/PostgREST sebagai
satu-satunya backend. Lihat keputusan arsitektur & tasklist di repo `skyward`:
`docs/plans/grand-revamp-plan.md` (gitignored, working doc).

## Prinsip inti

- **Go = sole engine.** Semua logika bisnis milik Go (simulasi, ekonomi, kredit, AI bot,
  mutasi fleet/routes/bank). Postgres = storage + constraints + safety-net trigger.
- **114 fungsi SQL yang ada = oracle transisi** (parity test saja, TIDAK dipakai prod).
- **Money = decimal** (float64 dilarang untuk uang).
- Kontrak REST: `docs/plans/skyward-api-contract.md` (repo skyward, gitignored).
- Pola mengikuti `majadu-api` (stdlib `net/http` + `pgx/v5`, error envelope,
  quadlet + Caddy + GHCR deployment).

## Stack

- Go 1.26, stdlib `net/http` (Go 1.22+ routing) — tanpa framework HTTP
- `pgx/v5` untuk Postgres
- JWT HS256 diimplementasikan dengan stdlib (`internal/auth`), tanpa dependency eksternal
- Password: **argon2id** (implemented di `internal/auth`)

## Struktur

```
cmd/server/              # entrypoint + routing + middleware chain
internal/config/         # env + godotenv (.env dev lokal) + validasi strict
internal/db/             # koneksi pool pgx + slow-query tracer
internal/domain/         # tipe bisnis: model + Money (decimal, bukan float64)
internal/store/          # akses DB: queries langsung ke tabel + store.Tx (transaksi)
internal/engine/         # SOLE BUSINESS LOGIC: simulation, economy, bots, credit,
                         # fleet/routes/bank mutation (shared helper player+bot)
internal/oracle/         # panggil fungsi SQL LAMA utk PARITY TEST saja (transisi)
internal/auth/           # JWT HS256 (sign/parse) — stdlib only
internal/handler/        # HTTP handlers: health, auth, game (thin — panggil engine)
internal/middleware/     # CORS, logging (slog), panic recovery, rate limit, request id, AuthGuard
internal/worker/         # world-tick worker loop → engine.Simulation.WorldTick
internal/logfile/        # log harian ala catalina.out (rotasi + retensi 7 hari)
internal/httperr/        # error envelope JSON konsisten
internal/build/          # versi binary (ldflags)
deploy/                  # quadlet units, Caddyfile, env template
scripts/deploy.sh        # setup/update ke VPS
```

## Endpoint (status)

Terakhir diverifikasi langsung (HTTP checks) pada 2026-09-05. Semua grup di bawah
**implemented** di `cmd/server/main.go` — bukan stub.

| Group | Status |
|---|---|
| `/healthz` `/readyz` `/version` | ✅ implemented |
| `/auth/*` (`register`, `login`, `me`) | ✅ implemented — argon2id + JWT HS256 stdlib |
| read resource (`/fleet`, `/routes`, `/finance/*`, `/bank/*`, `/leaderboard`, `/airports`, `/game-config`, `/simulation/state`) | ✅ implemented — semua di balik `AuthGuard` |
| mutation resource (`/fleet/*`, `/routes/*`, `/settings`, `/bank/*`, `/simulation/sync`, `/simulation/onboarding`, `/account`) | ✅ implemented — semua di balik `AuthGuard` |
| `/admin/*` (worker status, world tick, reset password) | ✅ implemented — di balik `AdminGuard` |
| WS `/ws` | ✅ implemented — JWT via query param `?token=` |

> ⚠️ Status frontend: Flutter (`apps/app`) masih 100% pakai Supabase SDK dan BELUM
> memanggil kontrak REST/WS ini. Rencana koneksi ada di `docs/plans/flutter-go-api-connection-plan.md`.

## Menjalankan

```bash
cp .env.example .env   # isi DATABASE_URL + SKYWARD_JWT_SECRET (dev)
make run               # go run ./cmd/server
make check             # vet + fmt + test
```

Prod: env dari podman `EnvironmentFile` (mode 600), bukan `.env`.

## Deploy

Instansi **dev sudah dihapus** (2026-09-05) — hanya prod yang ada.

Pipeline aktual (bukan GitHub Actions — tidak ada `.github/workflows` di repo ini):

```
push origin/main → GitHub webhook `skyward-monorepo` (HMAC) → VPS webhook service (:9000)
→ /srv/qouver/apps/skyward/scripts/deploy-vps.sh
  → git fetch origin main && git reset --hard origin/main
  → apps/api/ berubah?  podman build → native binary → restart skyward-api (user unit)
  → apps/app/ berubah?  podman build (Dockerfile.web, args dari env VPS mode 600)
                        → copy ke /srv/qouver/apps/skyward/web/ + restorecon
prod → https://api.qouver.com/skyward  → 127.0.0.1:8090 (DB skyward)
web  → https://skyward.qouver.com       → file_server /srv/qouver/apps/skyward/web
```

Catatan:
- `skyward-api` berjalan sebagai **native binary** (systemd user unit `skyward-api.service`),
  bukan container. `deploy/skyward-api.container` (GHCR) masih **aspirational** — belum dipakai.
- `scripts/deploy.sh` deprecated (2026-09-03) — deploy otomatis via webhook saja.
- Migrations DB disimpan di VPS: `/srv/qouver/apps/skyward/migrations/` (pola majadu —
  tidak di repo GitHub). Baseline sumber ada di repo skyward: `migrations/00_baseline.sql`.

## License

MIT
