# Skyward Operations Runbook

Status: current | Last verified against code: 2026-09-11

Practical operations for the solo owner. This file merges the former
`audit-queries.md`, `simulation-guide.md`, `owner-tools.md`, and
`backend-hardening-plan.md` into one surface. RPC-era instructions (Supabase
SQL Editor, Edge Functions, `select * from <rpc>()` gameplay wrappers) are gone;
the Go API in `apps/api` is authoritative and ops actions go through HTTP admin
endpoints.

## 1. Architecture Pointer

Skyward is a Flutter desktop/web frontend (`apps/app`) talking to an
authoritative Go backend (`apps/api`) over REST + WebSocket; Postgres remains the
economic authority underneath the Go process, which owns auth (JWT), the world
tick worker, and all mutations. The client is display-only and never simulates
authoritative outcomes. For the full component and data-flow picture see
[../architecture/overview.md](../architecture/overview.md).

## 2. Audit Queries Pack

Run these directly with `psql` against the same database the API uses. The
connection string is the `DATABASE_URL` environment variable read by
`apps/api/internal/config` (see `config.Load`, `config.go`). The API loads a
local `.env` in dev via `godotenv`.

```bash
# from repo root; DATABASE_URL is postgres://...
psql "$DATABASE_URL" -f -            # paste a query, or:
psql "$DATABASE_URL" -c "select ..."
```

Healthy values are noted per query. Queries that cannot be fully verified
against the current migrations are marked "(unverified)".

### 2.1 Player / bot sanity

Player account overview. `users.season_id`, `operational_status`,
`actor_type`, and `game_current_time` all exist in `00_baseline.sql`.

```sql
select id, username, company_name, actor_type, operational_status,
       hq_airport_iata, net_worth, game_current_time, season_id
from users
where actor_type = 'REAL'
order by created_at nulls last;
```

Bot population vs configured cap. `max_bot_count` is read from `game_config`
by `ProcessBots` in `apps/api/internal/engine/bots.go`; active bots exclude
`operational_status = 'Bankrupt'`.

```sql
select
  (select count(*) from users
    where actor_type='AI'
      and coalesce(operational_status,'Active') <> 'Bankrupt') as active_bots,
  (select (value #>> '{}')::int from game_config where key='max_bot_count') as max_bots;
```

Expect `active_bots <= max_bots` and, after a tick, `active_bots = max_bots`.
Bankrupt AI rows should not accumulate: `reapBankruptBots()` deletes them and
their dependents each tick (commit `521acf5`, `bots.go`).

Bankrupt bots that were not reaped (should normally be empty):

```sql
select id, username, company_name, operational_status, season_id
from users
where actor_type='AI' and operational_status='Bankrupt'
order by id;
```

Actor clock lag (in-game clocks only; this is not scheduler latency).
`users.game_current_time` and `season_clock.current_game_time` are both
`timestamptz` game-time fields.

```sql
select u.id, u.company_name, u.actor_type,
       u.game_current_time,
       s.current_game_time as season_game_time,
       s.current_game_time - u.game_current_time as game_time_lag
from users u
left join season_clock s on s.id = u.season_id
where u.actor_type = 'REAL'
order by game_time_lag desc nulls last;
```

### 2.2 Ledger vs bank_transactions coherence

Canonical cash lives in `bank_accounts.balance`; canonical movement lives in
`bank_transactions`. There is no `bank_transactions.created_at`; `game_date` is
the in-game timestamp. Verified columns from `00_baseline.sql`:
`account_id`, `user_id`, `transaction_type`, `amount`, `balance_after`,
`description`, `game_date`, `ifrs_category`, `ifrs_subcategory`.

Recompute each account balance from its ledger rows and compare with the stored
`balance`. Expect `delta = 0` for every row.

```sql
select a.user_id,
       a.account_type,
       a.balance                                   as stored_balance,
       coalesce(sum(t.amount), 0)                  as ledger_sum,
       a.balance - coalesce(sum(t.amount), 0)      as delta
from bank_accounts a
left join bank_transactions t on t.account_id = a.id
group by a.user_id, a.account_type, a.balance
having a.balance - coalesce(sum(t.amount), 0) <> 0
order by abs(a.balance - coalesce(sum(t.amount), 0)) desc;
```

IFRS classification distribution (dual purpose: income statement + cash flow):

```sql
select ifrs_category, ifrs_subcategory, count(*), sum(amount)
from bank_transactions
where game_date >= now() - interval '30 days'
group by ifrs_category, ifrs_subcategory
order by ifrs_category, ifrs_subcategory;
```

### 2.3 Route / demand checks

Active routes whose assigned aircraft is grounded or below the safety
threshold should be empty. `route_assignments.status` is `active|cancelled`;
`fleet_aircraft.status` is `grounded|active|maintenance`. `auto_grounding_threshold`
defaults to 40.

```sql
select r.id as route_id, r.origin_iata, r.destination_iata,
       f.id as fleet_id, f.status, f.condition
from route_assignments r
join fleet_aircraft f on f.id = r.assigned_aircraft_id
where r.status = 'active'
  and (f.status <> 'active' or f.condition < 40.00)
order by f.condition;
```

Active routes with no aircraft assigned (may be legitimate, but usually a
bug):

```sql
select id, user_id, origin_iata, destination_iata, ticket_price,
       flights_per_week, status
from route_assignments
where status = 'active' and assigned_aircraft_id is null
order by id;
```

Active world events that can move fuel, demand, capacity, or maintenance.
`game_events` has `event_type`, `effect_type`, `effect_target`,
`effect_value`, `start_game_time`, `end_game_time`, `is_active`.

```sql
select event_type, title, effect_type, effect_target, effect_value,
       start_game_time, end_game_time
from game_events
where is_active = true
order by start_game_time desc;
```

### 2.4 Achievement retention

`achievements` gained a `notified_at` column in
`migrations/14_wave5_achievement_notified.sql`; un-notified rows are delivered
on the next `POST /simulation/sync`. The `features/achievements/` Flutter module
was removed, so this is a backend/live-data audit surface. `game_date` is game
time; `unlocked_at` and `notified_at` are wall-clock write times.

```sql
select achievement_type, achievement_name,
       game_date, unlocked_at, notified_at
from achievements
where notified_at is null
order by unlocked_at desc
limit 50;
```

Stale un-notified rows older than a day (look for delivery regressions):

```sql
select count(*) as unnotified_older_than_1d
from achievements
where notified_at is null
  and unlocked_at < now() - interval '1 day';
```

### 2.5 finance_snapshots retention (migration 15)

`migrations/15_finance_snapshots_retention.sql` created `finance_snapshots`
(`user_id`, `snapshot_game_time`, `cash`, `net_worth`, `active_routes`,
`fleet_count`, `created_at`) with a unique key on
`(user_id, snapshot_game_time)`. The Go engine keeps one row per user per game
day and prunes to `financeSnapshotRetentionDays = 90` per user in
`apps/api/internal/engine/simulation.go`. **Retention lives only in Go** —
migration 15 creates the table/index/unique-key but has no SQL prune function;
never rely on a DB job for this.

Rows per user vs the 90-day cap (expect `snapshots <= 90`):

```sql
select user_id, count(*) as snapshots,
       min(snapshot_game_time) as oldest,
       max(snapshot_game_time) as newest
from finance_snapshots
group by user_id
having count(*) > 90
order by snapshots desc;
```

Duplicates for the same user/day (unique constraint should make this empty):

```sql
select user_id, date_trunc('day', snapshot_game_time) as day, count(*)
from finance_snapshots
group by user_id, day
having count(*) > 1
order by count(*) desc;
```

### 2.6 World tick / bank retention audit helpers

These functions exist in `00_baseline.sql` and are read-only audit surfaces.
They are still callable via `psql`; they are not exposed as HTTP endpoints
except the worker status route below.

> ⚠️ **Caveat (2026-09-12):** `get_world_tick_scheduler_health()` and
> `get_world_tick_guardrail_report()` predate the Go world-tick worker and
> still look at the pg_cron scheduler era. They may return stale or
> meaningless values now that the worker is in-process — verify before
> trusting, or retire them.

```sql
select * from get_world_tick_guardrail_report();
select * from get_world_tick_scheduler_health();
select * from prune_bank_transactions(true);   -- dry-run: rows that would be pruned
```

`prune_bank_transactions(p_dry_run boolean)` defaults to dry-run and deletes
against `bank_transactions.game_date` using the active
`season_clock.current_game_time` and the `bank_txn_raw_retention_game_days`
config key; rows with `game_date is null` are preserved.

## 3. Simulation Troubleshooting

The world tick is a Go loop (`apps/api/internal/worker/worker.go`) calling
`engine.WorldTick` (`apps/api/internal/engine/simulation.go`). Each tick:
advances `season_clock.current_game_time`, generates/deactivates events,
processes REAL players, processes bots, writes `world_tick_log`, and writes
`finance_snapshots` once per game day.

### 3.1 Worker status endpoint

`GET /admin/worker/status` returns the worker `Status` struct. It requires
`Authorization: Bearer <SKYWARD_ADMIN_TOKEN>` (`AdminGuard` in
`apps/api/internal/handler/admin.go`; registered in
`apps/api/cmd/server/main.go`).

```bash
curl -s -H "Authorization: Bearer $SKYWARD_ADMIN_TOKEN" \
  https://api.qouver.com/skyward/admin/worker/status | jq
```

Fields: `alive`, `last_tick_at`, `last_tick_ms`, `errors_count`,
`next_tick_after`, `status`. `status` is one of `initialized`, `running`, or
`stopped`. `GET /readyz` also fails with "world tick worker not alive" when the
worker is not alive (`handler/health.go`), so `readyz` is a fast liveness gate.

### 3.2 Stuck or failing tick

Symptoms: `last_tick_at` stops advancing, `errors_count` climbs, or `readyz`
returns unavailable.

- Trigger a manual tick (admin, synchronous):

  ```bash
  curl -s -X POST -H "Authorization: Bearer $SKYWARD_ADMIN_TOKEN" \
    https://api.qouver.com/skyward/admin/world/tick | jq
  ```

- Confirm the tick actually moved the clock and logged success:

  ```sql
  select season_id, started_at, finished_at, game_time_before,
         game_time_after, players_processed, bots_processed, status, message
  from world_tick_log
  order by started_at desc
  limit 10;
  ```

- Check the guardrail report for backwards ticks / actor lag:

  ```sql
  select * from get_world_tick_guardrail_report();
  ```

### 3.3 Backoff behavior

On a failed tick the worker increments `errors_count` and resets its ticker to
an exponential backoff: `backoff(n)` doubles each consecutive error, capped at
60 seconds (`worker.go`). A successful tick resets `errors_count` to 0 and the
ticker returns to the configured interval. The startup interval is
`SKYWARD_WORKER_TICK_INTERVAL_SECONDS` (default 60); the true tick cadence is
`season_clock.tick_interval_seconds` × `time_scale_multiplier` inside
`WorldTick`. Reading the live interval from `season_clock` each loop is a known
TODO (`worker.go`). If ticks are slow, inspect `errors_count` first — the
worker may be sitting in a 60s backoff while spamming the log.

### 3.4 Season clock drift

`season_clock.current_game_time` is advanced with an advisory lock per season,
so a stale or missing `status='active'` row will make `WorldTick` fail with
"no active season or lock failed". Check:

```sql
select id, label, current_game_time, last_tick_at,
       time_scale_multiplier, tick_interval_seconds, status
from season_clock
order by created_at;
```

Exactly one row should be `active`. Confirm recent ticks against game time:

```sql
with s as (select current_game_time from season_clock where status='active' limit 1)
select (select count(*) from world_tick_log where status='success') as success_ticks,
       (select max(finished_at) from world_tick_log) as last_finished,
       s.current_game_time
from s;
```

For per-actor drift, use the lag query in §2.1. `users.game_current_time` is
the actor cursor; `season_clock.current_game_time` is shared season time.

### 3.5 Bot population, reap, and cap

After commit `521acf5` ("advance bot simulation timeline, reap bankrupt bots,
cap population"), `ProcessBots` (`apps/api/internal/engine/bots.go`):

1. Simulates each active bot forward to the new season time via
   `ProcessPlayer` before decision handlers run (fixes frozen bots).
2. Calls `reapBankruptBots()`, deleting AI users with
   `operational_status='Bankrupt'` and their dependents (bank, finance,
   fleet, routes, loans, scores, bot profile). FK cascades make the dependent
   deletes defensive.
3. Ensures the active population is exactly `max_bot_count` by spawning one bot
   per tick until the cap is reached.
4. `spawnBot` randomizes `company_name` and retries up to 10 times on unique
   collisions, so the UNIQUE constraint can no longer silently cap the
   population at 3.

If bot count is below cap after many ticks, check `bot_profiles` and recent
`world_tick_log` errors; also confirm `max_bot_count` exists in `game_config`.
Bankrupt bots lingering means the reap path is not running (see §3.1/§3.2).

## 4. Owner Tools

Owner/admin actions are HTTP endpoints in `apps/api`, not Supabase RPCs. All
admin routes sit behind `POST/GET` handlers wrapped with `AdminGuard`, which
checks `Authorization: Bearer <SKYWARD_ADMIN_TOKEN>` (`handler/admin.go`,
`cmd/server/main.go`). The token comes from `SKYWARD_ADMIN_TOKEN` and is
required in prod (`config.validate`).

| Method + path | Purpose |
|---|---|
| `GET /admin/worker/status` | Worker alive/error/tick status (§3.1) |
| `POST /admin/world/tick` | Run one synchronous world tick; returns `WorldTickResult` (`ticks_processed`, `players_processed`, `bots_processed`, `game_time_after`) |
| `POST /admin/account/{id}/reset-password` | Set a user's password (min 6 chars) without email; body `{"password":"..."}` |

The route-optimizer and guardrail/scheduler-report admin endpoints are listed
as TODOs in `main.go` and are **not** implemented; use the SQL audit functions
in §2.6 for those reports until they land. There is also a non-admin
`POST /auth/reset-password` for username-based recovery (recovery credentials:
company name / CEO name / HQ), which is a normal auth route behind no admin
token.

Example admin calls:

```bash
# manual world tick
curl -s -X POST -H "Authorization: Bearer $SKYWARD_ADMIN_TOKEN" \
  https://api.qouver.com/skyward/admin/world/tick | jq

# reset a user's password
curl -s -X POST -H "Authorization: Bearer $SKYWARD_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"password":"new-secret"}' \
  https://api.qouver.com/skyward/admin/account/<user-id>/reset-password | jq
```

### Deploy pointer

Deployment manifests and Caddy snippets live under [`deploy/`](../../deploy).
`deploy/deploy-vps.sh` is the active webhook-driven deploy path; the API runs
as a native systemd user unit at `/srv/qouver/apps/skyward/bin/skyward-api`
(not a container — `skyward-api.container` is aspirational). `scripts/deploy.sh`
is deprecated for updates but its `setup` mode still installs the quadlet unit:

```bash
scripts/deploy.sh setup     # once: install quadlet unit + enable service
scripts/deploy.sh           # deprecated update path; prefer deploy/deploy-vps.sh
```

Prod API base: `https://api.qouver.com/skyward`; dev defaults to
`127.0.0.1:8090` (`PORT`, `HOST`).

## 5. Reset / Reseed Operations

`scripts/` contains only `deploy.sh`; there are **no standalone seeders** in
the repo.

**Bootstrap reality (corrected 2026-09-12):** the migrations capture *schema*
plus a handful of `game_config` rows (`09`, `11`), **not** the reference data.
`aircraft_models`, `airports`, and roughly 25 `game_config` keys (fuel price,
crew cost, wear rates, ticket base/km, all bot knobs, `credit_tier_config`)
exist only in the live database; a fresh environment that runs migrations
alone silently falls back to the Go hardcoded defaults and runs a different
economy. To bootstrap, restore those tables from a live data dump
(`pg_dump --data-only -t aircraft_models -t airports -t game_config …`) until
the seed migration lands (tracked as AUDIT-10 in the local audit action plan).

- Schema baseline: apply `migrations/00_baseline.sql` first, then
  `01_…` through `16_…` sequentially.
- Migrations are applied directly with `psql` against the target database, e.g.
  `psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -1 -f migrations/15_finance_snapshots_retention.sql`.
  Each migration header names its apply command.
- Player airline reset is a normal in-app mutation
  (`POST /settings/reset`, `SettingsReset` in
  `apps/api/internal/handler/mutation.go`), not a SQL console routine. It is
  auth-guarded and reloads bank/finance state after reset.
- Account deletion is the authed `DELETE /account` route (`AccountDelete`); for
  bot-only cleanup the engine reaps bankrupt AI users itself (§3.5).
- `finance_snapshots`, `achievements`, `bank_transactions`, and
  `world_tick_log` all retain/prune automatically via the worker and
  `prune_*` helpers; do not hand-delete them unless auditing.

If a reset leaves a player in a bad ledger state, prefer the in-app reset;
only if no valid post-reset progress must be preserved, delete the phantom
`bank_transactions` rows and re-align `users.game_current_time` to
`season_clock.current_game_time`.
