# Skyward Architecture Overview

Status: current | Last verified against code: 2026-09-11

This is the system-shape page for a new contributor or agent. It answers "what
are the moving parts and who owns the truth?" Deep dives live in the sibling
docs: [backend.md](backend.md), [frontend.md](frontend.md),
[database.md](database.md), and the product rules in
[`../standards/maintainer-standard.md`](../standards/maintainer-standard.md). Operational
procedures are in [`../operations/runbook.md`](../operations/runbook.md).

## System shape

Skyward is a Flutter Web/Desktop airline-management sim backed by an
authoritative Go API and PostgreSQL.

```
┌────────────────────────────────┐
│  Flutter client (apps/app)     │
│  Web + Desktop                 │
│  Cubit-owned state             │
│  • ApiClient  (HTTP, REST)     │
│  • GoRealtimeClient (WS)       │
└───────────────┬────────────────┘
                │  HTTPS / WSS
                │  dev : http://localhost:8090
                │  prod: https://api.qouver.com/skyward
                ▼
┌────────────────────────────────┐
│  skyward-api (apps/api, Go)    │
│  cmd/server  → HTTP + routing  │
│  handler     → thin HTTP glue  │
│  engine      → SOLE business   │
│                logic           │
│  worker      → world-tick loop │   ← same binary as the API
│  realtime    → WS hub          │
│  store       → SQL access      │
└───────────────┬────────────────┘
                │  pgx/v5
                ▼
┌────────────────────────────────┐
│  PostgreSQL                    │
│  storage + constraints +       │
│  safety-net triggers           │
└────────────────────────────────┘
```

The world-tick worker runs **inside the same process** as the HTTP server
(`cmd/server/main.go` constructs `worker.New(...)` and calls `wk.Start(ctx)`).
There is no separate cron/worker deployment.

## Request and auth flow

- The client authenticates with `username + password`
  (`POST /auth/register`, `POST /auth/login`). Passwords are hashed with
  **argon2id** and verified in `internal/auth` with no external JWT dependency.
- On success the API returns a **JWT HS256** signed with `SKYWARD_JWT_SECRET`.
  Claims are `sub` (the `public.users.id`), `username`, `exp`, `iat`.
- The client stores the token (`AuthTokenStore`) and injects
  `Authorization: Bearer <jwt>` on every request (`ApiClient`).
- `middleware.AuthGuard` validates the bearer token, then puts the resolved
  `user_id` into the request context (`middleware.UserIDFromContext`). Handlers
  call the engine with that id — there is no trust in a client-supplied user id.
- Admin/ops routes use a separate `handler.AdminGuard` token
  (`SKYWARD_ADMIN_TOKEN`), not the player JWT.

## Realtime (WebSocket)

The WS endpoint is `GET /ws?token=<jwt>` (`internal/handler/ws.go`). It
authenticates by parsing the same JWT, upgrades the connection, and registers a
`realtime.Client` on the `realtime.Hub`.

Client → server messages (`internal/handler/ws.go`):

- `{"action":"subscribe","channels":[...]}`
- `{"action":"unsubscribe","channels":[...]}`
- `{"action":"ping"}` → server replies `{"type":"pong"}`

Server → client events are notifications only. `hub.Broadcast(channel, event)`
and `hub.BroadcastAll(event)` emit
`{"type":"change","channel":"...","event":"INSERT|UPDATE|DELETE|world_tick"}`.
Realtime is a **freshness layer, not a source of truth**: clients react by
refetching over REST.

Channels broadcast by the code today:

- `fleet_aircraft` — purchase / sale / repair / seat config mutations
  (`internal/handler/mutation.go`)
- `route_assignments` — route create / delete / assign / freq-price
- `users` — settings save/reset, and each world tick
- `loans` — take / repay / refinance / finance-aircraft
- `bank_transactions` and `users`, plus a global `world_tick`, on every
  `engine.WorldTick`

The Flutter side shares one connection (`GatewayFactory.realtimeClient`) via
`GoRealtimeMixin.subscribeToRealtime`; it reconnects with exponential backoff
and re-subscribes. Cubits subscribe to the channels they care about and refetch
on change.

## Season clock and the world tick

Game time is server-owned; the Flutter client never advances it locally.

- `season_clock.current_game_time` is the shared season time;
  `users.game_current_time` is each actor's cursor.
- `engine.WorldTick` (`internal/engine/simulation.go`) locks the active season
  with `pg_try_advisory_xact_lock`, advances `current_game_time` by
  `tick_interval_seconds * time_scale_multiplier`, generates/deactivates game
  events, then processes every `REAL` player via `ProcessPlayer`.
- `ProcessPlayer` advances one actor by the elapsed game time: it runs the
  route loop, posts ledger rows, applies aircraft wear, advances the player
  cursor atomically (guarded `UPDATE`), and runs the day-boundary work when the
  game day rolls.
- Bots are processed by `engine.ProcessBots` (`internal/engine/bots.go`), which
  first runs each bot through the same shared `ProcessPlayer` path and then
  applies bot decisions.
- The tick interval: the worker's ticker is created from
  `SKYWARD_WORKER_TICK_INTERVAL_SECONDS` (default 60s). Season advancement
  itself uses `season_clock.tick_interval_seconds * time_scale_multiplier`. A
  TODO in `internal/worker/worker.go` notes that reading interval changes from
  `season_clock` on each tick is not implemented yet.

## What is authoritative server-side

All of the following are decided by the Go engine (Postgres is storage +
constraints), never by the client:

- **Finance ledger** — `engine.LedgerService`
  (`internal/engine/engine.go`): `DebitTx` / `CreditTx` / `DebitAccount` /
  `CreditAccount` update `bank_accounts.balance` and append
  `bank_transactions`. `bank_accounts` is canonical cash; `bank_transactions`
  is canonical money movement.
- **Banking and loans** — `engine.BankService` (`internal/engine/bank.go`):
  `TakeLoan`, `Repay`, `Refinance`, `FinanceAircraft`. The credit model lives in
  `internal/engine/dayboundary.go`: `calculateCreditScore`,
  `resolveCreditTier`, `ProcessCreditAtDayBoundary`, `ProcessLoanPayments`,
  `ProcessAircraftFinancingPayments`.
- **Bots** — `internal/engine/bots.go`: spawn, distress evaluation, fleet/route
  decisions, GAME-22 price response, bankruptcy, and population capping.
- **Demand and fares** — `routeDailyDemand`, `allocateCabins` in
  `internal/engine/simulation.go`; calibrated by migrations
  `05_demand_pool_scale.sql` and `06_cabin_fare_multipliers.sql`.
- **Achievements** — `internal/engine/achievements.go` (`EvaluateAchievements`,
  `ClaimUnnotifiedAchievements`), with `notified_at` from migration
  `14_wave5_achievement_notified.sql`.
- **Game events** — `GenerateGameEvents` / `DeactivateExpiredEvents` in
  `internal/engine/dayboundary.go`.
- **Fleet and routes** — `internal/engine/fleet.go` and
  `internal/engine/routes.go`.
- **Finance snapshots** — written once per game day by `WorldTick`, pruned to a
  bounded window (migration `15_finance_snapshots_retention.sql`).

## The client rule

The Flutter app **displays backend results and sends user commands**. It must
not implement authoritative economy logic locally: no local cash math, no local
flight-revenue calculation, no local credit scoring, no local clock advance.
Valid client concerns are presentation, navigation, controller/focus lifecycle,
and optimistic UI that is always reconciled against a server refetch.

## Deployment

The API runs as a native binary behind Caddy; the Flutter web build is served
as static files. Container/quadlet manifests, Caddy configs, and the deploy
script live in [`../../deploy/`](../../deploy/). Environment and operational
detail are indexed in [`../README.md`](../README.md) and
[`../../apps/api/README.md`](../../apps/api/README.md).
