# Skyward Database Design

Status: current | Last verified against code: 2026-09-11

This is the current schema reference for the PostgreSQL database behind
`skyward-api`. For the runtime owner of writes see [backend.md](backend.md);
for the client see [frontend.md](frontend.md) and the system shape in
[overview.md](overview.md).

## Canonical notes

- **Migrations are sequential**: `migrations/00_baseline.sql` …
  `migrations/15_finance_snapshots_retention.sql`.
- `00_baseline.sql` is a consolidated dump of the live schema (310 KB) that
  **replaced 58 older migration files on 2026-07-22**. It is the baseline, not
  a numbered feature migration.
- The old `Migration NN` numbering (27, 33–46) and timestamped filenames are
  obsolete and must not be used.
- **Application functions (the Supabase RPC era) are no longer the write
  path.** The Go engine executes SQL directly through a `pgx` pool. See
  [Current write path](#current-write-path).

## Current write path

`apps/api` is the authoritative writer. It connects with `pgx/v5`'s
`pgxpool` (`internal/db/db.go`: `NewPool`, `MaxConns = 10`, slow-query tracer).
Data access is split between `internal/store` (reads + a `Tx` helper) and
`internal/engine` (mutations):

- `store.Store.Tx(ctx, fn)` opens one transaction per mutation, committing on
  success and rolling back on error (`internal/store/store.go`).
- `internal/engine/*` run raw SQL against tables (`users`, `bank_accounts`,
  `bank_transactions`, `fleet_aircraft`, `route_assignments`, `loans`,
  `season_clock`, `finance_snapshots`, …) inside those transactions. The
  package doc is explicit: *"Semua mutasi engine berjalan dalam satu transaksi
  (store.Tx). Tidak ada fungsi SQL yang dipanggil."* — engine mutations use
  direct table SQL, not the legacy RPC functions.
- Handlers (`internal/handler/mutation.go`) are thin glue: resolve the
  authenticated `user_id` from context, call an engine service
  (`Fleet.Purchase`, `Routes.Create`, `Bank.TakeLoan`, `Settings.Reset`, …),
  then broadcast a realtime change.
- The world tick is `engine.WorldTick` (`internal/engine/simulation.go`), run
  by the in-process `worker` goroutine (same binary as the API, replacing
  pg_cron). It locks the season with `pg_try_advisory_xact_lock`, advances
  `season_clock.current_game_time`, processes actors, writes `finance_snapshots`
  once per game day, and appends `world_tick_log`.
- A handful of SQL helper functions remain callable and are invoked by the Go
  code where useful (for example `get_hq_prefix`), but the gameplay RPC surface
  is legacy. The functions still exist in the baseline; migration 02 removed the
  legacy custom-session functions (`register_company`, `login_company`,
  `validate_session`) and the `sessions` table.

## Table groups

The baseline defines 16 tables. `finance_snapshots` was captured later by
migration 15, so the current schema has 17 application tables.

### Identity / users

- `users` — actor record for both players and bots. Columns include
  `id`, `username`, `company_name`, `ceo_name`, `game_current_time`,
  `last_active_at`, `net_worth`, `hq_airport_iata`, `auto_grounding_threshold`,
  `operational_status` (`Active`/`Bankrupt`), `consecutive_negative_days`,
  `recovery_streak_days`, `season_id`, `auth_user_id`, `onboarding_completed`,
  `actor_type` (`REAL`/`AI`).
  There is **no `users.cash` column**; cash lives in `bank_accounts`.
- `bot_profiles` — backend-only bot behavior state keyed by `user_id`:
  `archetype`, `distress_stage`
  (`stable`/`cautious`/`defensive`/`desperate`), `consecutive_loss_days`,
  `secondary_hub_iata`, `recovery_loan_taken`, and a set of cooldown
  timestamps (`last_growth_action_at`, `last_route_change_at`,
  `last_pricing_review_at`, `last_repair_action_at`,
  `last_route_optimization_at`, `last_route_audit_at`,
  `last_financial_action_at`).

### Fleet

- `fleet_aircraft` — authoritative fleet state: `user_id`,
  `aircraft_model_id`, `acquisition_type`
  (`purchase`/`lease`/`finance`), `condition`, `status`
  (`grounded`/`active`/`maintenance`), `tail_number`, `economy_seats`,
  `business_seats`, `first_class_seats`, `nickname`, `acquired_game_date`.
- `aircraft_models` — static catalog: `manufacturer`, `model_name`, `type`
  (`regional_turboprop`/`regional_jet`/`narrow_body_jet`/`wide_body_jet`),
  `range_km`, `capacity`, `speed_kmh`, `fuel_burn_per_km`,
  `maintenance_cost_per_hour`, `purchase_price`, `lease_price_per_month`,
  `turnaround_hours`, and `min_credit_tier` (added by migration 10).

### Routes

- `route_assignments` — authoritative route network: `user_id`, `origin_iata`,
  `destination_iata`, `distance_km`, `ticket_price`, `assigned_aircraft_id`,
  `flights_per_week` (1–168), `status` (`active`/`cancelled`).
- `airports` — static registry: `iata` (PK), `name`, `city`, `country`,
  `latitude`, `longitude`, `demand_index` (1–100).

### Finance

- `bank_accounts` — **canonical cash**. Columns: `user_id`, `account_type`
  (only `operating`), `balance`, timestamps. Player cash lives here.
- `bank_transactions` — **canonical money movement**. Columns: `account_id`,
  `user_id`, `transaction_type`
  (`debit`/`credit`/`payment`/`deposit`/`disbursement`/`refinance`/`late_fee`/
  `accrual`/`refund`), `amount`, `balance_after`, `description`, `game_date`,
  `ifrs_category`, `ifrs_subcategory`. Every economic event should leave an
  auditable row.
- `loans` — debt state: `user_id`, `principal`, `interest_rate`,
  `remaining_balance`, `weekly_payment`, `monthly_payment`, `term_months`,
  `status` (`active`/`paid_off`/`defaulted`/`repossessed`), `loan_type`
  (`unsecured`/`secured`/`credit_line`/`aircraft_financing`),
  `collateral_aircraft_id`, `missed_payments`, `taken_at`,
  `originated_game_date`.
- `credit_scores` — current per-player credit state: `score`, `tier`,
  factor columns (`fleet_health_score`, `revenue_stability_score`,
  `debt_ratio_score`, `cash_reserves_score`, `profit_history_score`),
  `computed_at`.
- `credit_score_history` — historical snapshots of the same factor columns plus
  `game_date` and `computed_at`.
- `finance_snapshots` — daily per-user trend rows captured by migration 15:
  `user_id`, `snapshot_game_time`, `cash`, `net_worth`, `revenue_30d`,
  `expense_30d`, `active_routes`, `fleet_count`, unique on
  `(user_id, snapshot_game_time)`. Written once per game day and pruned to a
  retention window (see [Migrations](#migrations)).

### Game state

- `game_config` — key/value JSONB runtime configuration (`key`, `value`,
  `category`, `unit`, `description`, `updated_at`). Drives starting cash,
  demand pools, cabin fares, tier policy, and bot tuning.
- `season_clock` — shared world-time authority: `label`, `current_game_time`,
  `last_tick_at`, `time_scale_multiplier`, `tick_interval_seconds`, `status`
  (`draft`/`active`/`paused`/`completed`).
- `world_tick_log` — operational audit trail for tick attempts: `season_id`,
  `started_at`, `finished_at`, `game_time_before`, `game_time_after`,
  `ticks_processed`, `real_seconds_processed`, `game_seconds_processed`,
  `players_processed`, `bots_processed`, `status`, `message`.
- `game_events` — time-bounded world events: `event_type`, `title`,
  `description`, `effect_type`, `effect_target`, `effect_value`,
  `start_game_time`, `end_game_time`, `is_active`.
- `achievements` — per-user achievement rows: `user_id`, `achievement_type`,
  `achievement_name`, `description`, `unlocked_at`, `game_date`, and
  `notified_at` (added by migration 14 for reliable unlock toasts).

## Season clock and chronology

- `season_clock.current_game_time` is the shared game clock.
- `users.game_current_time` is each actor's cursor and follows the season clock
  after migration 03.
- Player-facing chronology uses in-game timestamps such as
  `bank_transactions.game_date`, `credit_score_history.game_date`,
  `loans.originated_game_date`, and `game_events.start_/end_game_time`.
- `last_tick_at`, `world_tick_log.started_at`/`finished_at`, `computed_at`,
  `taken_at`, and generic `created_at`/`updated_at` are **real-world metadata**,
  not gameplay time.

## RLS and security posture

Security is declared in migrations 01 and 02:

- `01_security_phase5_rls.sql` enables RLS on the user-facing tables (`users`,
  `bank_accounts`, `bank_transactions`, `fleet_aircraft`, `route_assignments`,
  `loans`, `credit_scores`, `credit_score_history`, `achievements`) and on
  reference tables (`aircraft_models`, `airports`, `game_config`,
  `season_clock`, `bot_profiles`).
  - User tables get tenant-isolation policies scoped through
    `auth_user_id = auth.uid()`.
  - Global definition tables get public read-only `SELECT` policies.
- `02_security_phase6_legacy_cleanup.sql` drops the legacy custom-session RPCs
  (`register_company`, `login_company`, `validate_session`) and the `sessions`
  table.

The Go API connects as the database owner and enforces ownership itself
(`middleware.AuthGuard` resolves `user_id` from the bearer JWT; handlers never
trust a client-supplied id). RLS is the defense-in-depth layer, not the primary
authorization check for API traffic.

## Safety-net triggers

The baseline attaches these triggers, which reconcile derived state:

| Trigger | Table | Purpose |
|---|---|---|
| `create_default_bank_account` | `users` (AFTER INSERT) | create the operating account for a new user |
| `fleet_reconcile_net_worth` | `fleet_aircraft` (INSERT/UPDATE/DELETE) | recompute net worth on fleet change |
| `trg_bank_balance_reconcile_net_worth` | `bank_accounts` (balance/user_id change) | recompute net worth on cash change |
| `trg_loan_reconcile_net_worth` | `loans` (remaining_balance/status/user_id change) | recompute net worth on debt change |
| `trg_user_hq_change` | `users` (hq_airport_iata change) | sync tail numbers on HQ change |

The historical `on_auth_user_created` → `handle_new_auth_user()` trigger
belongs to the retired Supabase Auth path and is not part of the current
Go-API runtime.

## Migrations

Files are applied in numeric order.

| File | What it changes | Applies to |
|---|---|---|
| `00_baseline.sql` | Consolidated live schema dump (tables, functions, triggers, RLS) replacing 58 old files on 2026-07-22 | whole schema |
| `01_security_phase5_rls.sql` | Enable RLS + tenant/global policies | user + reference tables |
| `02_security_phase6_legacy_cleanup.sql` | Drop legacy custom-session RPCs and `sessions` table | auth |
| `03_sync_user_game_time_to_season_clock.sql` | Catch up `users.game_current_time` to the active season clock; redefine `reset_user_airline` to seed from `season_clock` | `users`, `reset_user_airline` |
| `04_wave1_game_review_fixes.sql` | Value-based lease repair cost; GRU airport name; UAE demand recalibration | `perform_actor_aircraft_repair`, `airports` |
| `05_demand_pool_scale.sql` | Add `demand_pool_scale` (default 290.0) fixed daily demand pool knob | `game_config` |
| `06_cabin_fare_multipliers.sql` | Add cabin fare multipliers and willingness shares | `game_config` |
| `07_wave4_aviation_data_fixes.sql` | Aviation data integrity: speeds, ranges, fuel burn, turnaround, lease prices, China/India demand tiers, airport cleanup | `aircraft_models`, `airports`, `fleet_aircraft`, `route_assignments`, `users`, `bot_profiles` |
| `08_wave4_corrective.sql` | Restore hubs downgraded by 07's China CASE; keep RKZ low | `airports` |
| `09_wave5_starting_cash.sql` | Raise starting cash to $25M | `game_config.starting_cash` |
| `10_wave5_aircraft_tiers.sql` | Add `min_credit_tier` and set progression gates | `aircraft_models` |
| `11_wave5_bot_price_response.sql` | Tighten bot competitive price threshold to 0.08 | `game_config` |
| `12_wave5_china_demand_corrective.sql` | Restore LXA/XNN demand to 70 | `airports` |
| `13_wave5_reset_starting_cash.sql` | Fix `reset_user_airline` to read config starting cash ($25M) | `reset_user_airline` |
| `14_wave5_achievement_notified.sql` | Add `achievements.notified_at` + backfill so tick unlocks can be toasted exactly once | `achievements` |
| `15_finance_snapshots_retention.sql` | Capture `finance_snapshots` schema, add trend index, align FK cascade; Go worker writes one row per game day and prunes | `finance_snapshots` |

## Schema truths to keep straight

- Do **not** document legacy names such as `user_fleet`, `user_routes`, or
  `financial_ledger` as live tables.
- Do **not** document `users.cash` as canonical cash.
- `bank_accounts` (cash) and `bank_transactions` (movement) are the finance
  core; `finance_snapshots` is only the bounded trend cache.
- The old `Migration 27/33–46` references and timestamped migration filenames
  in earlier docs are obsolete.
