# Skyward Go Backend

Status: current | Last verified against code: 2026-09-11

This page documents `apps/api` (module `skyward-api`) as it actually is: package
layout, the simulation engine, the HTTP surface, the worker, and the testing
state. For the system shape and request/auth flow, see
[overview.md](overview.md). For the client that consumes this API, see
[frontend.md](frontend.md). For table-level detail, see
[database.md](database.md). For operational procedures, see
[`../operations/runbook.md`](../operations/runbook.md).

## Stack

- Go 1.26, stdlib `net/http` (Go 1.22+ routing) — no HTTP framework.
- `github.com/jackc/pgx/v5` for PostgreSQL, `github.com/gorilla/websocket` for
  `/ws`, `golang.org/x/crypto` for argon2id, `github.com/joho/godotenv` for dev
  `.env`.
- JWT HS256 is implemented with the standard library in `internal/auth`; there
  is no external JWT dependency.
- Postgres is the storage + constraint/safety-net layer. The Go engine is the
  sole business-logic authority (`apps/api/README.md`).

## Package map

| Package | LOC (approx, non-test) | Responsibility |
|---|---|---|
| `internal/engine` | ~2,986 | Sole business logic: simulation, economy, bots, credit, fleet/routes/bank/settings mutations, achievements, events. |
| `internal/handler` | ~1,168 | Thin HTTP handlers: health, auth, reads, mutations, admin, WS. Parse + validate request, call engine/store, map to JSON. |
| `internal/store` | ~890 | Direct DB access and read models (`read.go`, `users.go`, `store.go`), plus `store.Tx` helper. |
| `internal/worker` | ~166 | World-tick loop + exponential backoff + status snapshot. |
| `internal/realtime` | ~163 | WebSocket hub: clients, channels, broadcast events. |
| `internal/auth` | ~130 | JWT HS256 sign/parse + argon2id hash/verify. |
| `internal/middleware` | ~307 | Recover, request-id, logging (slog), CORS, rate limit, `AuthGuard`. |
| `internal/config` | ~162 | Env loading (.env in dev), strict validation (fail-closed in prod). |
| `internal/db` | ~80 | `pgxpool` pool creation + slow-query tracer (200ms threshold). |
| `internal/domain` | ~87 | Business type definitions. |
| `internal/httperr` | ~124 | Consistent JSON error envelope + `WriteJSON`. |
| `internal/logfile` | ~105 | Daily log writer (retention, catalina.out style). |
| `internal/build` | ~11 | Version/commit/date set via ldflags. |

Entrypoint: `cmd/server/main.go` — config load, logger setup, DB pool, engine,
realtime hub, worker start, route registration, middleware chain, graceful
shutdown.

## Simulation engine domains

### Ledger

`internal/engine/engine.go`, type `LedgerService`:

- `GetBalance(ctx, userID)` — operating `bank_accounts` balance.
- `DebitTx` / `CreditTx` — mutate balance inside a caller-supplied `pgx.Tx` and
  append a `bank_transactions` row with IFRS category/subcategory and game time.
- `DebitAccount` / `CreditAccount` — open their own transaction (used by the
  per-route simulation loop).
- `GenerateTailNumber`, `GetUserGameTime`, `GetUserGameTimeTx`.

`bank_accounts.balance` is canonical cash; `bank_transactions` is canonical
money movement.

### Banking and loans

`internal/engine/bank.go`, type `BankService`:

- `TakeLoan`, `Repay`, `Refinance`, `FinanceAircraft` — all return
  `*MutationResult`.
- `tierRate(ctx, tier, field, fallback)` reads `game_config.credit_tier_config`.

`internal/engine/dayboundary.go`:

- `ProcessLoanPayments` — weekly/monthly loan servicing, 10% late fee on missed
  payments, default after 4 missed payments (grounds collateral).
- `ProcessAircraftFinancingPayments` — the aircraft-financing path.
- `ProcessCreditAtDayBoundary` — writes `credit_scores` and
  `credit_score_history`.
- `calculateCreditScore` — five sub-scores (fleet health, revenue stability,
  debt ratio, cash reserves, profit history), total clamped to 0–1000.
- `resolveCreditTier` / `creditTierRank` — Platinum/Gold/Standard tiering.
- `CurrentCreditTier`.

### World tick and player simulation

`internal/engine/simulation.go`:

- `WorldTick` — lock active season, advance `season_clock.current_game_time`,
  generate/deactivate events, process all `REAL` players, process bots, write
  `world_tick_log`, write daily `finance_snapshots`, broadcast realtime.
- `ProcessPlayer` — per-actor simulation: config load, event multipliers,
  per-user advisory lock, route loop posting ledger rows, aircraft wear,
  atomic cursor advance, day-boundary hook, achievements, bankruptcy.
- `processDayBoundary`, `applyBankruptcy`, `shouldBankruptOnNegativeDays`,
  `getConfigNum`.
- Economy helpers: `crewCostFor`, `allocateCabins`, `demandWeight`,
  `distanceDemandFactor`, `routeDailyDemand`.

### Demand pools and cabin fares

- `routeDailyDemand` implements a fixed daily passenger pool split across the
  player's flights, with price elasticity and a distance demand factor. Created
  by migration `05_demand_pool_scale.sql` (`demand_pool_scale`, fallback 290.0).
- `allocateCabins` distributes the pool across economy/business/first by
  willingness-to-pay. Created by migration `06_cabin_fare_multipliers.sql`
  (business 1.5x, first 2.5x; willingness 80/15/5). Go fallbacks in
  `simulation.go` must stay in sync with those config rows.

### Bots

`internal/engine/bots.go`:

- `ProcessBots` — two passes: simulate every bot through the shared
  `ProcessPlayer` path, then apply decisions (repair, route lifecycle, fleet
  growth, route creation, pricing, financial).
- `spawnBot` — random archetype (Regional / Aggressive / Balanced), random
  company name, retry on unique collision.
- `botEvaluateDistress` — computes `botDistress` (stage, caps, growth chance,
  price multiplier).
- `botRespondPrice` — **GAME-22** strengthened price response
  (commit `cb0a7bc`): reacts to smaller undercuts and converges in 1–2 reviews
  rather than drifting ~2% per cycle.
- `botHandlePricing`, `botHandleRepair`, `botHandleFleetGrowth`,
  `botHandleRouteLifecycle`, `botHandleRouteCreation`, `botHandleFinancial`.
- `reapBankruptBots` — purge path that keeps the AI population bounded.
- Population cap: `max_bot_count` config (default 5); the cap and bankrupt reaping
  are commit `521acf5` ("advance bot simulation timeline, reap bankrupt bots,
  cap population").
- `routeWeeklyProfit` / `routePerformance` use the same demand-pool + cabin
  model as players (GAME-25).

### Achievements

`internal/engine/achievements.go`:

- `EvaluateAchievements` — idempotent insert of earned achievements.
- `ClaimUnnotifiedAchievements` — atomically claims (`UPDATE ... RETURNING`)
  rows with `notified_at IS NULL`; only the user-facing sync path claims, so the
  background tick cannot consume a toast it cannot show.
- `notified_at` comes from migration `14_wave5_achievement_notified.sql`.

### Game events

`internal/engine/dayboundary.go`:

- `GenerateGameEvents` — 5% chance per tick; types `fuel_shock`,
  `demand_surge`, `weather_disruption`, `maintenance_shock`; 72-hour duration.
- `DeactivateExpiredEvents`.

### Fleet and routes

- `internal/engine/fleet.go`, `FleetService`: `Purchase`, `Lease`, `Sell`,
  `Repair`, `TerminateLease`, `ConfigureSeats`, plus tier gating
  (`checkTierGate`, `tierGateMessage`, `validateSeats`, `calcLeaseDeposit`).
- `internal/engine/routes.go`, `RoutesService`: `Create`, `Assign`,
  `UpdateFreqPrice`, `Delete`, plus `haversine` and `calcMaxWeeklyFlights`.
- `internal/engine/settings.go`, `SettingsService`: `Save`, `Reset`,
  `DeleteAccount`.

### Finance snapshots retention

Migration `15_finance_snapshots_retention.sql` captured the `finance_snapshots`
table and the per-game-day cadence/pruning. The engine writes one row per user
per game day in `WorldTick` and prunes to `financeSnapshotRetentionDays = 90`
(`internal/engine/simulation.go`).

## HTTP surface

All routes are registered in `cmd/server/main.go`. Groups:

- **Health / ops**: `GET /healthz`, `GET /health`, `GET /readyz`,
  `GET /version` (`handler.HealthHandler`).
- **Auth** (public): `POST /auth/register`, `POST /auth/login`,
  `POST /auth/reset-password`; `GET /auth/me` is guarded.
- **WebSocket**: `GET /ws` — JWT via `?token=<jwt>` query param.
- **Read APIs** (`AuthGuard`): `/simulation/state`, `/game-config`, `/fleet`,
  `/aircraft-models`, `/routes`, `/airports`, `/finance/snapshot`,
  `/finance/transactions`, `/finance/history`, `/leaderboard`,
  `/leaderboard/competitors/{id}`, `/bank/credit`, `/bank/credit/history`,
  `/bank/loans`, `/bank/accounts`, `/bank/transactions`,
  `/fleet/available`, `/fleet/{id}`, `/fleet/models/{modelId}/latest`,
  `/settings/grounding-threshold`, `/events`, `/achievements`.
- **Mutations** (`AuthGuard`): `/fleet/purchase`, `/fleet/lease`,
  `/fleet/{id}/sell`, `/fleet/{id}/repair`, `/fleet/{id}/terminate-lease`,
  `PATCH /fleet/{id}/seats`, `POST /routes`, `POST /routes/{id}/assign`,
  `PATCH /routes/{id}`, `DELETE /routes/{id}`, `PATCH /settings`,
  `POST /settings/reset`, `DELETE /account`, `POST /bank/loans`,
  `POST /bank/loans/{id}/repay`, `POST /bank/loans/{id}/refinance`,
  `POST /bank/finance-aircraft`, `POST /simulation/sync`,
  `POST /simulation/onboarding`.
- **Admin** (`handler.AdminGuard` with `SKYWARD_ADMIN_TOKEN`):
  `GET /admin/worker/status`, `POST /admin/world/tick`,
  `POST /admin/account/{id}/reset-password`.

Middleware chain (outermost first): `Recover` → `RequestID` → `Logging` →
`CORS` → `RateLimit` → mux. Errors use the `internal/httperr` JSON envelope
(`unauthorized`, `validation`, `not_found`, `rate_limited`, `internal`, ...).
Successful mutations may broadcast a realtime event on `fleet_aircraft`,
`route_assignments`, `users`, or `loans`.

## Worker loop

`internal/worker/worker.go`:

- `New(pool, tickFn, logger, enabled, intervalSec)` — the tick function is
  `eng.WorldTick` wired in `cmd/server/main.go`.
- `Start(ctx)` runs the loop in a goroutine; disabled when
  `SKYWARD_WORKER_ENABLED=false`.
- On error it increments `ErrorsCount` and backs off exponentially from 1s,
  doubling up to a 60s ceiling; on success the counter resets.
- `Status()` feeds `GET /admin/worker/status`
  (`alive`, `last_tick_at`, `last_tick_ms`, `errors_count`, `next_tick_after`,
  `status`). Note: `next_tick_after` is declared in the struct but never
  populated by the worker.
- The ticker interval comes from `SKYWARD_WORKER_TICK_INTERVAL_SECONDS`. A code
  TODO notes it does not yet re-read `season_clock.tick_interval_seconds` at
  runtime; season advancement itself uses the DB value.

## Testing state

Verification command: `cd apps/api && go test ./...` (or `make test` from the
repo root, which also runs Flutter tests).

- **Tested**: `internal/engine` (achievements, bankruptcy, bot economics /
  pricing / spawn, cabin allocation, demand, fleet, route economics, tier gate)
  and `internal/auth`.
- **Untested**: `internal/handler`, `internal/store`, `internal/worker`,
  `internal/realtime`, `internal/middleware`, `internal/config`,
  `internal/httperr`, `internal/db`, `internal/logfile`, `cmd/server`. There are
  no `_test.go` files in these packages.

## Known divergences and TODOs

- `internal/domain.Money` is declared as a `string` with a comment that it
  should become `shopspring/decimal`. That dependency is **not** in `go.mod`,
  and the engine/store use `float64` for money today. The README's "Money =
  decimal (float64 dilarang)" describes the intended target, not the current
  code.
- `internal/domain` is currently a type-definition skeleton; no package in the
  module imports it (verified by grep).
- The `// TODO Fase 5+` block at the end of `registerRoutes` lists admin routes
  (owner route-optimizer, guardrail-report, scheduler-health) that are not yet
  implemented.
- PostgreSQL migration files live in `migrations/00_baseline.sql` through
  `15_finance_snapshots_retention.sql`; older "Migration NN" and timestamp
  names are obsolete.
