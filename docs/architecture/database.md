# Skyward Database Design

Last verified against code, migrations, and linked live schema on 2026-07-09.

This file records the current public schema shape and the operational meaning
of the tables that actually exist in the linked runtime.

## Live table inventory

Linked live schema currently exposes these public tables:

1. `achievements`
2. `aircraft_models`
3. `airports`
4. `bank_accounts`
5. `bank_transactions`
6. `bot_profiles`
7. `credit_score_history`
8. `credit_scores`
9. `fleet_aircraft`
10. `game_config`
11. `game_events`
12. `loans`
13. `route_assignments`
14. `season_clock`
15. `users`
16. `world_tick_log`

## Core authority model

## Clock Domain Map

Use this when deciding whether a timestamp should be shown to players, treated
as backend audit metadata, or compared against another field.

Frontend-facing game chronology:
- `users.game_current_time`
- `season_clock.current_game_time`
- `bank_transactions.game_date`
- `credit_score_history.game_date`
- `world_tick_log.game_time_before`
- `world_tick_log.game_time_after`
- `game_events.start_game_time`
- `game_events.end_game_time`
- `achievements.game_date` when present

Real-time backend or ops metadata:
- `season_clock.last_tick_at`
- `world_tick_log.started_at`
- `world_tick_log.finished_at`
- `credit_score_history.computed_at`
- `loans.taken_at`
- `achievements.unlocked_at`
- generic row metadata such as `created_at` / `updated_at`

Current product rule:
- player-facing chronology should default to in-game timestamps
- real-time timestamps are acceptable in the product only as clearly labeled
  metadata, not as the main gameplay timeline

Current chronology audit status:
- loan origination now uses `loans.originated_game_date`
- loan repayment ledger rows now use exact `users.game_current_time`
- aircraft financing origination and down-payment rows now use exact shared
  game time
- lease termination ledger rows now use exact `users.game_current_time`
- `achievements.game_date` remains the intended player-facing chronology field;
  currently dormant as the Flutter module was removed 2026-06-27
- native SQL audits now also prove exact game-clock timestamps for purchase /
  lease / repair / sale ledger rows

### `users`

Primary human-player actor record.

Important fields:
- `id`
- `auth_user_id`
- `username`
- `company_name`
- `ceo_name`
- `hq_airport_iata`
- `game_current_time`
- `season_id`
- `net_worth`

Important notes:
- `auth_user_id` is the ownership bridge from `auth.uid()`
- `cash` is no longer the canonical money store
- `handle_new_auth_user()` is attached to `auth.users` via `on_auth_user_created` trigger
- declared in migration `20260709180000_declare_auth_trigger.sql`

### `bank_accounts`

Canonical cash storage.

Important fields:
- `user_id`
- `account_type`
- `balance`

Operational rule:
- player cash lives here, not in `users.cash`

### `bank_transactions`

Canonical money-movement trail.

Important fields:
- `account_id`
- `user_id`
- `transaction_type`
- `amount`
- `balance_after`
- `ifrs_category`
- `ifrs_subcategory`
- `description`
- `game_date`

Operational rule:
- purchases, loan disbursements, repayments, maintenance, lease carrying costs,
  and route/simulation financial effects are expected to leave an auditable row here
- `game_date` is in-game time, not wall-clock time; comparing it directly to
  real-world timestamps such as `loans.taken_at` is misleading

### `fleet_aircraft`

Authoritative fleet state.

Important fields:
- `user_id`
- `aircraft_model_id`
- `nickname`
- `tail_number`
- `acquisition_type`
- `condition`
- `status`
- `economy_seats`
- `business_seats`
- `first_class_seats`

### `route_assignments`

Authoritative route-network state.

Important fields:
- `user_id`
- `origin_iata`
- `destination_iata`
- `distance_km`
- `ticket_price`
- `flights_per_week`
- `assigned_aircraft_id`

### `loans`

Authoritative debt state.

Important fields:
- `user_id`
- `loan_type`
- `principal`
- `remaining_balance`
- `interest_rate`
- `weekly_payment`
- `monthly_payment`
- `status`
- `collateral_aircraft_id`
- `originated_game_date`

Operational note:
- `taken_at` is a real-world origination timestamp
- `originated_game_date` is the player-facing in-game origination timestamp
- related bank-ledger rows such as `loan_disbursement` are stamped with
  `bank_transactions.game_date`, which follows the shared game calendar
- repayment-side ledger rows are also stamped with the exact shared game clock

### `credit_scores`

Current credit state per player.

Important fields:
- `user_id`
- `score`
- `tier`
- factor columns used by the bank/credit model

### `credit_score_history`

Historical credit-score snapshots.

Important fields:
- `user_id`
- `score`
- factor scores
- `game_date`
- `computed_at`

Operational note:
- `game_date` is the in-game scoring date used by the client history view
- `computed_at` is the real-world timestamp when the backend wrote the snapshot

### `season_clock`

Shared world-time authority.

Important fields:
- `current_game_time`
- `last_tick_at`
- `time_scale_multiplier`
- `tick_interval_seconds`
- `status`

Operational note:
- `current_game_time` is the shared in-game world clock
- `last_tick_at` is the real-world timestamp of the latest successful backend tick

### `world_tick_log`

Operational audit trail for world-tick attempts.

Important fields:
- `season_id`
- `started_at`
- `finished_at`
- `game_time_before`
- `game_time_after`
- `ticks_processed`
- `players_processed`
- `bots_processed`
- `status`
- `message`

Operational note:
- `started_at` and `finished_at` are real-world scheduler timestamps
- `game_time_before` and `game_time_after` are the in-game clock interval that
  the tick advanced

### `bot_profiles`

Backend-only bot behavior state.

Important fields:
- `user_id` (PK, FK to users)
- `archetype` (Regional/Aggressive/Balanced)
- `distress_stage` (stable/cautious/defensive/desperate)
- `consecutive_loss_days` — tracks chronic route losses
- `secondary_hub_iata` — optional non-HQ origin for route creation
- `recovery_loan_taken` — prevents multiple recovery loans per desperate episode
- Cooldown timestamps: `last_growth_action_at`, `last_route_change_at`,
  `last_pricing_review_at`, `last_repair_action_at`, `last_route_optimization_at`,
  `last_route_audit_at`, `last_financial_action_at`

### `game_events`

Time-bounded world events that modify simulation economics.

Important fields:
- `event_type`
- `effect_type`
- `effect_target`
- `effect_value`
- `start_game_time`
- `end_game_time`
- `is_active`

Operational note:
- `start_game_time` and `end_game_time` are in-game activation bounds, not
  wall-clock schedule timestamps

### `achievements`

Player achievement tracking.

Operational note:
- `unlocked_at` is a real-world write timestamp
- `game_date` captures the in-game moment the achievement was awarded when the
  backend provides it
- the `features/achievements/` Flutter module was removed on 2026-06-27; this
  table has no active Flutter consumer currently

## Static reference tables

### `aircraft_models`

Static aircraft catalog used by fleet, bank, planning, and simulation logic.

### `airports`

Static airport registry used by routes, settings, and planning flows.

### `game_config`

Key-value runtime configuration.

Used for:
- starting cash
- credit-tier policy
- lease deposit policy
- economy/simulation constants that remain backend-owned
- bot behavior tuning (8 entries added in migration 36):
  `bot_consecutive_loss_days_threshold`, `bot_route_optimization_cooldown_hours`,
  `bot_secondary_hub_chance`, `bot_fleet_diversity_chance`,
  `bot_purchase_cash_multiplier`, `bot_competitive_price_threshold`,
  `bot_recovery_loan_amount`, `bot_loan_repayment_ratio`

## Live trigger surface

Repo-local schema defines and the audit pass verified these trigger paths:

1. `create_default_bank_account` on `users`
2. `fleet_reconcile_net_worth` on `fleet_aircraft`
3. `trg_user_hq_change` on `users`
4. `trg_bank_balance_reconcile_net_worth` on `bank_accounts`
5. `trg_loan_reconcile_net_worth` on `loans`

Additional auth-side truth:
- `handle_new_auth_user()` is attached to `auth.users` via `on_auth_user_created` trigger
- declared in migration `20260709180000_declare_auth_trigger.sql`

## Live cron / ops surface

Repo-defined scheduler jobs:

1. `skyward_world_tick` → `ensure_world_current()`
2. `skyward_prune_bank_transactions` → `prune_bank_transactions(false)`
3. `skyward_prune_world_tick_log` → `prune_world_tick_log()`

Note: migration 34 added `tick_interval_seconds` and `max_catchup_ticks` as
configurable `game_config` entries so tick behavior can be tuned without
redeploying. The original `skyward_compact_world_tick_log` cron job was replaced
by `skyward_prune_world_tick_log` in migration 37 because pg_cron failed to
execute DELETE through the `compact_world_tick_log(false)` parameterized call.

## Important schema truths

- Do not document legacy names like `user_fleet`, `user_routes`, or `financial_ledger` as live tables.
- Do not document `users.cash` as canonical cash.
- `bank_accounts` and `bank_transactions` are now the core finance surface.
- Finance history in the current Flutter runtime is bank-transaction-driven.
- `bank_transaction_daily_summary` and `bank_transactions_archive` were removed
  from the live schema by migration `27`.
- raw `bank_transactions` retention is now a delete-only ops surface driven by
  `prune_bank_transactions(false)` and `bank_txn_raw_retention_game_days`.

## Verification note

This file is about the current live schema, not every historical migration idea.
If a table is absent from the linked live schema, it should not be described
here as if it were runtime truth.
