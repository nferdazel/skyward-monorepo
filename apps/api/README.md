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
- Password: **argon2id** (direncanakan Fase 3 — butuh `golang.org/x/crypto`)

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

| Group | Status |
|---|---|
| `/healthz` `/readyz` `/version` | ✅ implemented |
| `/auth/*` (register/login/me) | ⏳ stub — Fase 3 |
| resource game (`/fleet`, `/routes`, `/finance`, `/bank`, ...) | ⏳ stub 501 — Fase 4-5 |
| `/admin/worker/status` | ✅ implemented (worker status) |
| WS `/ws` | ⏳ Fase 7 |

## Menjalankan

```bash
cp .env.example .env   # isi DATABASE_URL + SKYWARD_JWT_SECRET (dev)
make run               # go run ./cmd/server
make check             # vet + fmt + test
```

Prod: env dari podman `EnvironmentFile` (mode 600), bukan `.env`.

## Deploy

Pola identik majadu-api: CI build → push `ghcr.io/nferdazel/skyward-api:{dev,main}`
→ VPS rootless podman + quadlet pull & run → Caddy `api.qouver.com` path routing:

```
dev  → https://api.qouver.com/skyward-dev  → 127.0.0.1:8091 (DB skyward_dev)
prod → https://api.qouver.com/skyward      → 127.0.0.1:8090 (DB skyward)
```

Langkah sekali (setup): `./scripts/deploy.sh setup dev` (lihat `scripts/deploy.sh`).

Migrations DB disimpan di VPS: `/srv/qouver/skyward/migrations/` (pola majadu —
tidak di repo GitHub). Baseline sumber ada di repo skyward: `migrations/00_baseline.sql`.

## License

MIT
