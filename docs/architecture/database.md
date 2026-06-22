# Skyward Database Design

Last verified against code and migration history on 2026-06-22.

This is the current high-level database design record.
It replaces older raw-schema walkthroughs that no longer matched the live app.

## Core tables

### `season_clock`
Shared season-clock foundation for the future world-tick engine.

Important fields:
- `current_game_time`
- `last_tick_at`
- `time_scale_multiplier`
- `tick_interval_seconds`
- `status`

Phase 2 compatibility rule:
- `users.season_id` and `ai_competitors.season_id` link actors to the active season

Phase 3 foundation:
- `process_world_tick` advances `season_clock.current_game_time`
- `ensure_world_current` wraps world ticking for future commands and snapshots
- `world_tick_log` records scheduler/manual tick attempts

Phase 4 scheduler:
- `skyward_world_tick` pg_cron job calls `ensure_world_current(NULL)` every minute
- `world_tick_scheduler_config` records the desired scheduler settings
- `get_world_tick_scheduler_health()` reports clock/log/job status for audits
  without granting client roles direct `cron.job` access

Phase 5 actor tick:
- `process_world_tick` advances actor rows after moving the season clock
- `users.game_current_time` and `ai_competitors.game_current_time` are retained
  as actor progress cursors, not independent clocks
- `process_simulation_delta` remains the Flutter compatibility RPC but no longer
  calculates elapsed game time from legacy real-world activity anchors

Phase 5.1 bootstrap:
- active `season_clock.current_game_time` is moved forward to the existing actor
  frontier if legacy actors already progressed beyond the new season clock
- new player/bot rows start at the active season time instead of hard-coded
  `2020-01-01`
- ambiguous world-tick SQL references are qualified for live RPC execution

Phase 7/8/11-lite guardrails:
- `get_world_tick_guardrail_report()` provides a read-only world-clock health
  report for actor lag, actor-ahead drift, backwards tick logs, and recent
  successful world ticks

Phase 9 daily simulation:
- aggregate economy formulas are retained as internal segment processors
- `process_player_simulation_to_time` and `process_all_bots_simulation_to_time`
  now advance actors through deterministic game-day boundaries
- multi-day catch-up can produce per-day ledger/streak effects instead of one
  final-day aggregate update

### `users`
Company profile and simulation anchor.

Important fields used by Flutter:
- identity/session-linked profile data
- `auth_user_id` as the future Supabase Auth linkage column
- `company_name`
- `ceo_name`
- `cash` or compatibility-mapped cash payload
- `game_current_time`
- `season_id`
- HQ/grounding-related settings fields

New columns (migration 72):
- `password_hash` column was dropped — authentication is handled entirely by
  Supabase Auth

New columns (migration 78):
- `buffered_cargo_revenue` — buffered cargo revenue accumulator, written to
  `financial_ledger` as a separate line item at the game-day boundary

Security Phase 1 note:
- `auth_user_id` is now the forward path for binding authenticated callers to
  gameplay rows through `auth.uid()`
- the runtime still uses custom session RPCs until the auth cutover phases are
  completed

Security Phase 2 note:
- new users can now be bootstrapped from `auth.users` into `public.users`
  through an insert trigger
- the planned username-only auth UX depends on synthetic auth emails and
  server-side auto-confirmed auth user creation

Security Phase 3/4 note:
- Flutter auth now restores and destroys real Supabase Auth sessions instead of
  custom `sessions` tokens
- client-facing gameplay and finance RPCs are moving to auth-bound wrappers
  that resolve `public.users.id` from `auth.uid()`

Security Phase 5 note:
- Row Level Security is enabled on the app-facing read tables
- auth-bound client wrappers now execute as security definers so authenticated
  callers no longer need direct table write privileges
- legacy custom-session auth RPCs are no longer part of the client runtime path

Security Phase 6 note:
- the legacy `sessions` table and the custom-session auth functions have been
  removed from the live runtime model

### `global_game_settings`
Global game configuration used by nearly every simulation RPC.
Contains starting cash, fuel price, safety limits, bot count, and lease deposit settings.

### `aircraft_models`
Static aircraft catalog used for acquisition and planning.
Last live baseline verified on 2026-06-01: `48` rows.

New columns (migration 77):
- `turnaround_hours` — ground-handling time in hours between landing and next
  takeoff. Set by aircraft size class: ≤80 seats = 0.5h, 81–200 = 0.75h,
  201–350 = 1.5h, >350 = 2.0h

### `airports`
Static airport registry used by route creation and settings HQ selection.
Last live baseline verified on 2026-06-01: `239` rows.

### `user_fleet`
Owned and leased aircraft.
This is the authoritative source for:
- acquisition type
- tail number
- hull condition
- seat configuration
- assigned/grounded operational state
- scheduled-maintenance slot wear recovery inputs

New columns (migration 77):
- `total_flights` — total flights completed by this airframe since acquisition
- `last_a_check_at` — flight count at which the last A-check was performed (every 500 flights)
- `last_c_check_at` — flight count at which the last C-check was performed (every 3000 flights)

New column (migration 78):
- `buffered_cargo_revenue` — buffered cargo revenue accumulator for bot actors

### `user_routes`
Authoritative route network state.
This is the source for:
- route endpoints
- schedule
- ticket price
- assigned aircraft
- distance
- ASK/RPK/load outputs returned to the client
- airport-demand-backed passenger demand inputs via joined `airports.demand_index`

### `financial_ledger`
Transaction history for finance analytics and audit views.

Phase 15 compaction foundation:
- raw retention is actor-relative in game days
- `get_financial_ledger_compaction_report()` exposes dry-run summary buckets
- `compact_financial_ledger(FALSE)` can roll old rows into
  `financial_ledger_summary` and then delete the covered raw rows
- compaction is manual only in this phase; no scheduler is wired yet

### `financial_ledger_summary`
Daily actor-level summary buckets for compacted `financial_ledger` history.

This table preserves finance audit signal while reducing long-term growth from
per-transaction ledger rows. Summary rows are keyed by actor, game date,
transaction type, and category, with a derived month bucket for faster rollups.

### `world_tick_log`
Audit log for shared season-clock tick attempts.

This table is intentionally separate from `financial_ledger`; it records engine
clock advancement, not airline business transactions.

Phase 14 compaction foundation:
- raw retention is driven by `data_retention_policy.world_tick_log_raw_real_days`
- `get_world_tick_log_compaction_report()` exposes dry-run summary buckets
- `compact_world_tick_log(FALSE)` can roll old rows into
  `world_tick_daily_summary` and then delete the covered raw rows
- compaction is manual only in this phase; no scheduler is wired yet

### `game_events`
Time-bounded world events that modify simulation economics.

Event types: `fuel_shock`, `demand_surge`, `weather`, `regulatory`.

Important fields:
- `event_type` — category of the event
- `effect_type` — what the event modifies (`fuel_price`, `demand_index`, `airport_tax`)
- `effect_target` — airport IATA code or `global`
- `effect_value` — multiplier or absolute value
- `start_game_time` / `end_game_time` — time window
- `is_active` — whether the event is currently in effect

RLS: world-readable, service-role writes only.
Index: `game_events_active_lookup_idx` on `(effect_type, effect_target, is_active, start_game_time, end_game_time)`.

Migration 75 creates this table and wires `generate_game_events()` and
`deactivate_expired_events()` into `process_world_tick`.

### `financial_snapshots`
Daily financial snapshots for historical trend visualization.

Important fields:
- `user_id` — references `users(id)`
- `game_date` — one row per user per game day
- `cash` / `net_worth` — balance snapshot
- `daily_revenue` / `daily_expense` — that day's totals
- `fleet_count` / `route_count` — operational footprint

RLS: users can only read their own snapshots.
Index: `financial_snapshots_user_date_idx` on `(user_id, game_date DESC)`.

Migration 76 creates this table and records daily snapshots at game-day
boundaries from `process_player_simulation_to_time`.

### `world_tick_daily_summary`
Daily UTC summary buckets for compacted `world_tick_log` history.

This table preserves operational audit signal while reducing long-term growth
from minute-level tick rows.

### `world_tick_scheduler_config`
Desired scheduler configuration for the shared season-clock pg_cron job.

This is an operational record. The actual scheduled job still lives in pg_cron's
`cron.job` table.

### `data_retention_policy`
Configuration values for future storage maintenance.

Phase 12/13 behavior:
- records size thresholds and future retention targets
- does not delete or compact data
- supports `get_database_size_report()` and `get_table_size_report()`

Phase 14 usage:
- `world_tick_log_raw_real_days` is now consumed by world-tick log compaction
  dry runs and manual compaction

Phase 15 usage:
- `player_ledger_raw_game_days` and `bot_ledger_raw_game_days` are now
  consumed by ledger compaction dry runs and manual compaction

## Backend responsibilities

The database is responsible for:
- validating liquidity and transactional constraints
- processing simulation catch-up
- calculating passenger demand from both pricing elasticity and airport demand
- applying recurring lease/operations effects
- applying scheduled-maintenance slot recovery and grounded safeguards
- preserving anti-anomaly constraints
- generating leaderboard payloads
- generating competitor insights
- reporting database/table size for free-tier maintenance planning
- generating and expiring time-bounded world events
- computing hub bonus, airport congestion, and competition factors
- applying seasonal demand modifiers and fare-class elasticity
- tracking maintenance check milestones (A-check, C-check)
- computing cargo revenue and non-linear degradation
- recording daily financial snapshots for historical trends

## Migration policy

Migration files live in:
- `migrations/`

Apply them in numeric order:
- `01_...sql` onward

The migration folder is historical and cumulative.
When diagnosing current behavior, use:
1. active Flutter code paths
2. the latest relevant migrations
3. the RPC contract map

## Maintenance rule

Do not treat old schema examples in historical docs as canonical truth.
Current truth is defined by:
- the live migrations
- the active RPCs
- the code paths that parse their results

For catalog replenishment, use the repo-local workflow in:
- `data/README.md`
