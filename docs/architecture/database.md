# Skyward Database Design

Last verified against code, migrations, and linked live schema on 2026-06-26.

This file records the current public schema shape and the operational meaning
of the tables that actually exist in the linked runtime.

## Live table inventory

Linked live schema currently exposes these public tables:

1. `achievements`
2. `aircraft_models`
3. `airports`
4. `bank_accounts`
5. `bank_transaction_daily_summary`
6. `bank_transactions`
7. `bank_transactions_archive`
8. `bot_profiles`
9. `credit_score_history`
10. `credit_scores`
11. `fleet_aircraft`
12. `game_config`
13. `game_events`
14. `loans`
15. `route_assignments`
16. `season_clock`
17. `users`
18. `world_tick_log`

## Core authority model

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
- live DB verification confirms `handle_new_auth_user()` is attached to `auth.users`
- repo-local public migrations still do not declare that auth-side trigger attachment

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
- `total_flights`
- `last_a_check_at`
- `last_c_check_at`

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

Operational note:
- `taken_at` is a real-world origination timestamp
- related bank-ledger rows such as `loan_disbursement` are stamped with
  `bank_transactions.game_date`, which follows the shared game calendar

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
- `game_date` / historical timestamp fields used by the client history view

### `season_clock`

Shared world-time authority.

Important fields:
- `current_game_time`
- `last_tick_at`
- `time_scale_multiplier`
- `tick_interval_seconds`
- `status`

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

### `bot_profiles`

Backend-only bot behavior state.

Important fields:
- per-bot cooldown state
- distress / recovery metadata
- humanization and inertia controls

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

### `achievements`

Player achievement tracking.

Operational note:
- `unlocked_at` is a real-world write timestamp
- `game_date` captures the in-game moment the achievement was awarded when the
  backend provides it

### `bank_transaction_daily_summary`

Compacted analytical rollups for bank transaction history.

Current status:
- backend-written
- weakly consumed by the app
- should be treated as an audit/ops-support table unless product wiring expands

### `bank_transactions_archive`

Archive / compaction support table.

Current status:
- backend-only keep
- not part of normal app runtime reads

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

## Live trigger surface

Repo-local schema defines and the audit pass verified these trigger paths:

1. `create_default_bank_account` on `users`
2. `fleet_reconcile_net_worth` on `fleet_aircraft`
3. `trg_user_hq_change` on `users`
4. `trg_bank_balance_reconcile_net_worth` on `bank_accounts`
5. `trg_loan_reconcile_net_worth` on `loans`

Additional auth-side truth:
- `handle_new_auth_user()` is live-attached to `auth.users`
- that attachment is proven in the linked DB
- that attachment is not declared by the repo's public migrations

## Live cron / ops surface

Repo-defined scheduler jobs:

1. `skyward_world_tick` → `ensure_world_current()`
2. `skyward_compact_bank_transactions` → `compact_bank_transactions(false)`
3. `skyward_compact_world_tick_log` → `compact_world_tick_log(false)`

## Important schema truths

- Do not document legacy names like `user_fleet`, `user_routes`, or `financial_ledger` as live tables.
- Do not document `users.cash` as canonical cash.
- `bank_accounts` and `bank_transactions` are now the core finance surface.
- Finance history in the current Flutter runtime is bank-transaction-driven.

## Verification note

This file is about the current live schema, not every historical migration idea.
If a table is absent from the linked live schema, it should not be described
here as if it were runtime truth.
