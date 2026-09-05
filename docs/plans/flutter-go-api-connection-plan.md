# Plan: Koneksi Flutter ↔ Go API (skyward-api)

Status: **draft — dibuat 2026-09-05 berdasarkan verifikasi langsung (HTTP checks + audit repo).**

## 1. Konteks

Skyward sedang migrasi backend dari Supabase/PostgREST ke `apps/api` (Go, REST + WS),
sesuai `apps/api/README.md` ("Go = sole engine"). Migrasi backend-nya sudah jauh
(handler auth/read/mutation **fully implemented**), tapi sisi frontend belum di-wire sama sekali.

Hasil verifikasi langsung (2026-09-05):

| Cek | Hasil |
|---|---|
| `GET https://api.qouver.com/skyward/healthz` | 200 `{"status":"ok"}` — API live |
| `GET /skyward/fleet`, `/auth/me`, `POST /simulation/sync` (tanpa token) | 401 `"missing bearer token"` — handler real (bukan stub 501) |
| `GET /skyward/ws` (handshake) | 401 `"missing token"` — WS handler implemented (JWT via query param) |
| `GET /skyward/rest/v1`, `/auth/v1`, `/realtime/v1`, `/functions/v1` | **404** — Go API TIDAK speak protokol Supabase SDK |
| `https://skyward.qouver.com` | 200 — Flutter web release build live (hash routing) |
| `https://skyward.vercel.app` | 200 — tapi template Next.js + MUI, **bukan** app Skyward |

## 2. Masalah inti (gap)

1. **Protokol beda.** `apps/app` 100% pakai `supabase_flutter` (`.rpc()`, `.from()`, realtime
   Postgres Changes). Go API speak kontrak REST sendiri (`/fleet`, `/routes`, `/bank/*`, `/ws`).
   Tidak ada satu pun kode client HTTP/WS ke Go API di `apps/app/lib`.
2. **Build config salah arah.** `app_env.g.dart` (committed) & `Dockerfile.web` dulu
   mengarahkan `SUPABASE_URL` ke `https://api.qouver.com/skyward` (URL Go API). Akibatnya
   build web mana pun dari repo ini manggil `Supabase.initialize` ke URL yang 404 di semua
   path SDK → app mati di flow auth.
   - **Sudah diperbaiki** di workstream ini: hardcoded key dihapus, build-arg wajib dari env VPS
     (mode 600), lihat `apps/app/Dockerfile.web`, `deploy/deploy-vps.sh`,
     `deploy/env/skyward-prod.env.example`.
3. **CORS origin salah.** `CORS_ALLOWED_ORIGINS` menunjuk `https://skyward.vercel.app`
   (template Next.js). Origin asli Flutter web = `https://skyward.qouver.com`.
   - **Sudah diperbaiki** di `deploy/env/skyward-prod.env.example` (perlu di-apply ke VPS).

## 3. Arsitektur target

```
Flutter (apps/app)                 Go API (apps/api)                  Postgres
──────────────────────             ─────────────────────             ─────────
Cubits ── *Gateway (abstrak) ──>  ApiClient (http + WS) ──> REST    engine → store
                                          │                /auth/*   (114 fungsi SQL =
                                          └── WS /ws ─────> hub       oracle parity only)
```

Prinsip yang dipertahankan:
- Client TIDAK pernah menghitung ekonomi/simulasi lokal (tetap di engine Go / SQL).
- Pola **gateway abstract + impl konkret** yang sudah ada di Flutter dipertahankan —
  ganti `Supabase*Gateway` dengan `Go*Gateway` satu per satu tanpa menyentuh Cubit.
- Uang tetap `decimal` di Go (`internal/domain`), bukan float64.

## 4. Pemetaan endpoint (Supabase → Go)

Kontrak lama (`docs/architecture/supabase-contracts.md`) → endpoint baru (dari `apps/api/cmd/server/main.go`):

| Surface Supabase (lama) | Endpoint Go (baru) |
|---|---|
| Edge Function `register-with-username` | `POST /auth/register` |
| login via Supabase Auth | `POST /auth/login` |
| `auth.me` / auto-login | `GET /auth/me` (Bearer JWT) |
| RPC `process_simulation_delta` | `POST /simulation/sync` |
| RPC `get_finance_snapshot` | `GET /finance/snapshot` |
| read `bank_transactions`, `users`, dll. | `GET /finance/transactions`, `GET /finance/history`, `GET /bank/transactions`, `GET /bank/accounts` |
| RPC fleet (`purchase_aircraft`, `lease_aircraft`, `repair_aircraft`, `sell_aircraft`, `terminate_aircraft_lease`, `configure_aircraft_seats`) | `POST /fleet/purchase`, `POST /fleet/lease`, `POST /fleet/{id}/repair`, `POST /fleet/{id}/sell`, `POST /fleet/{id}/terminate-lease`, `PATCH /fleet/{id}/seats` |
| read `fleet_aircraft`, `aircraft_models` | `GET /fleet`, `GET /fleet/available`, `GET /aircraft-models` |
| RPC routes (`create_route`, `assign_aircraft_to_route`, `update_route_frequency_and_price`, `delete_route`) | `POST /routes`, `POST /routes/{id}/assign`, `PATCH /routes/{id}`, `DELETE /routes/{id}` |
| read `routes`, `airports`, `route_assignments` | `GET /routes`, `GET /airports` |
| RPC bank (`take_loan`, `repay_loan`, `refinance_loan`, `finance_aircraft`) | `POST /bank/loans`, `POST /bank/loans/{id}/repay`, `POST /bank/loans/{id}/refinance`, `POST /bank/finance-aircraft` |
| read `loans`, `credit_score_history` | `GET /bank/loans`, `GET /bank/credit`, `GET /bank/credit/history` |
| RPC `get_global_leaderboard`, `get_competitor_insights` | `GET /leaderboard`, `GET /leaderboard/competitors/{id}` |
| RPC settings (`save_airline_settings`, `reset_user_airline`) | `PATCH /settings`, `POST /settings/reset` |
| `delete-account` Edge Function | `DELETE /account` |
| Realtime Postgres Changes (`users`, `fleet_aircraft`, `route_assignments`, `bank_transactions`, `loans`, `bank_accounts`) | WS `GET /ws?token=<jwt>` (hub sudah ada di `internal/realtime`) |

Catatan:
- Error envelope Go: `{"error":{"code":...,"message":...}}` (`internal/httperr`) — client harus
  parse ini dan map ke `*GatewayException` yang sudah dipakai Cubit.
- Response game API memakai snake_case JSON (`company_name`, `game_current_time`, dll.) —
  beda dengan payload Supabase; sesuaikan di gateway (bukan di UI).

## 5. Fase eksekusi

### Phase 0 — Hygiene build & deploy ✅ (selesai di workstream ini)
- Hapus key hardcoded dari `Dockerfile.web` / `deploy-vps.sh` (pindah ke env VPS mode 600).
- `deploy/Caddyfile.skyward.qouver.com` — site Caddy untuk static web build.
- CORS origin → `https://skyward.qouver.com`.
- Docs status diperbarui.

### Phase 1 — Core API client di Flutter
1. `apps/app/pubspec.yaml`: tambah `http` (direct dependency; web-compatible).
   `web_socket_channel` sudah ada di lockfile via supabase — jadikan direct dep saat Phase 4.
2. `lib/core/config/app_env.dart`: tambah `apiBaseUrl` (env `SKYWARD_API_URL`, default
   `http://localhost:8090` dev) + regenerate `app_env.g.dart` via build_runner.
3. `lib/core/api/api_client.dart` (baru): base URL, timeout, header `Authorization: Bearer`,
   parse error envelope → `ApiException`.
4. `lib/core/api/auth_token_store.dart` (baru): simpan JWT via `shared_preferences`
   (sudah dependency) — menggantikan sesi Supabase.
5. Deploy plumbing: `Dockerfile.web` + `deploy-vps.sh` wajib kirim `SKYWARD_API_URL`
   (baca dari env VPS mode 600).

> ✅ Selesai 2026-09-05. 13 unit test baru (`test/layer1_unit/api/`) hijau, `flutter analyze` bersih.
> Catatan build_runner: output `.g.dart` di-cache — ubah `.env` butuh
> `dart run build_runner clean` dulu baru rebuild, kalau tidak envied tidak jalan ulang.
> Committed `app_env.g.dart` sengaja berisi placeholder (bukan kredensial asli) —
> Dockerfile prod regenerate dari env asli saat build.

### Phase 2 — Migrasi auth
- `SupabaseAuthGateway` → `GoAuthGateway`: `POST /auth/register`, `POST /auth/login`,
  `GET /auth/me`; auto-login dengan JWT tersimpan; logout = hapus token.
- `main.dart`: `SupabaseManager.initialize()` dibungkus try/catch (tidak fatal kalau
  Supabase gagal) — tapi init belum dihapus karena gateway feature lain masih
  pakai Supabase sampai Phase 3 selesai.
- Login Go exact-match (case-sensitive) sedangkan register menormalisasi —
  `GoAuthGateway` menormalisasi username client-side (mirror SQL
  `normalize_username`) sebelum login.
- Reset password user-facing belum ada di Go API (hanya `/admin/account/{id}`) →
  `resetPassword` melempar pesan jelas sampai endpoint tersedia.
- **Kriteria selesai:** register → login → auto-login → me jalan penuh tanpa Supabase.

> ✅ Selesai 2026-09-05. 10 unit test baru (`go_auth_gateway_test.dart`) hijau,
> 273 test total lolos, `flutter analyze` bersih. Kontrak diverifikasi LIVE ke
> `api.qouver.com/skyward`: register → 201 `{token,user}`; `GET /auth/me` → 200
> (user langsung); login → 200; cleanup `DELETE /account` → sukses.

### Phase 3 — Migrasi feature gateway (satu per satu, urut ketergantungan)
Urutan: `SettingsGateway` → `SimulationGateway` → `FleetGateway` → `RoutesGateway` →
`BankGateway` → `FinanceGateway` → `LeaderboardGateway`.
Per feature:
1. Implement `Go*Gateway` memakai `ApiClient` (lihat tabel mapping di atas).
2. Ikuti pola resync pasca-mutasi yang sudah ada (simulation sync + reload silang cubit).
3. Jalankan test layer 1 (gateway test) + widget test feature tsb.
4. **Parity check:** bandingkan hasil vs RPC Supabase lama / fungsi SQL oracle sebelum cutover.
5. Cutover impl `*Gateway` di composition root, simpan impl lama untuk rollback.

### Phase 4 — Realtime via WS `/ws`
- Ganti subscription Postgres Changes dengan WS `GET /ws?token=...` (`internal/realtime.Hub`).
- Event channel/type mengikuti hub yang ada; sesuaikan `RealtimeCubitMixin`.
- Realtime tetap freshness aid — resync eksplisit pasca-mutasi dipertahankan.

### Phase 5 — Cleanup
- Hapus `supabase_flutter`, `postgrest` dari pubspec; hapus `SupabaseManager`,
  `Supabase*Gateway`, `DevModeManager` path lama; rework dev-mode (mock gateway).
- Update docs: `docs/architecture/supabase-contracts.md` → arsip/status migrasi,
  `docs/README.md` runtime state, `apps/app/README.md`.
- Hapus `SUPABASE_*` dari env build (ganti `SKYWARD_API_URL`).

## 6. Kredensial & keamanan

- **Repo publik**: tidak boleh ada secret apa pun (key, token) di repo/script/Dockerfile.
- Semua rahasia hanya di VPS: `/srv/qouver/apps/skyward/env/skyward-prod.env` (chmod 600).
- JWT HS256: `SKYWARD_JWT_SECRET` (sudah wajib di prod, divalidasi `config.Load`).
- Anon key Supabase yang lama tidak relevan lagi setelah Phase 5 — dicabut dari Supabase project.

## 7. Testing & rollout

- `make analyze` + `make test` (flutter + go) hijau di tiap fase.
- Test baru: `test/layer1_unit/api/*` (ApiClient), `test/layer1_unit/cubits/*_gateway_test.dart`
  di-switch ke `Go*Gateway` dengan `mocktail`.
- Live smoke: `curl https://api.qouver.com/skyward/healthz`; register/login via curl untuk
  memastikan JWT flow sebelum cutover Flutter.
- Rollout: API sudah live → deploy web baru (deploy-vps.sh) dengan `SKYWARD_API_URL`.
- Rollback per feature: balikin impl gateway lama (interface sama, jadi aman).

## 8. Dokumen yang harus diupdate di workstream ini

- [x] `apps/app/Dockerfile.web`, `deploy/deploy-vps.sh`, `deploy/env/skyward-prod.env.example`
- [x] `deploy/Caddyfile.skyward.qouver.com` (baru)
- [x] `apps/api/README.md` (status endpoint)
- [x] `apps/app/README.md` (deployment)
- [x] `docs/README.md` (runtime state)
- [ ] `docs/architecture/supabase-contracts.md` (tandai transisi) — saat Phase 3 berjalan
- [ ] `docs/architecture/api-contract.md` (sinkronkan payload) — saat Phase 3 berjalan