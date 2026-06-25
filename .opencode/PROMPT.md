# Project Context

## What This Is

Skyward is a Flutter airline management sim backed by Supabase/Postgres. Flutter handles UI, session flow, and read-side orchestration. The backend is authoritative for world time, economy, fleet state, bank balances, credit, AI behavior, and operational validation.

Players run an airline by acquiring aircraft, opening routes, setting prices, managing debt, and competing against AI carriers on a shared leaderboard. The economy is bank-centric: cash lives in `bank_accounts`, money movement lives in `bank_transactions`, and simulation writes financial consequences server-side.

## Current Technical Shape

- Frontend: Flutter / Dart with feature-first structure and Cubit-only state management
- Backend: Supabase Postgres with SECURITY DEFINER RPCs, RLS, pg_cron, and trigger-driven reconciliation
- Migrations in repo: `migrations/00_baseline.sql` through `migrations/17_bot_decision_tick_alignment.sql`
- Tests: `239` passing tests across `37` files
- Static health: `flutter analyze` clean as of `2026-06-26`

## Core Architecture

### Frontend

- Feature modules under `lib/features/`
- Gateways isolate Supabase access from cubits
- Direct table reads for read models, RPC-heavy writes for authoritative mutations
- Realtime subscriptions used for selected tables

### Backend

- Canonical cash: `bank_accounts.balance`
- Canonical money trail: `bank_transactions`
- Net worth is derived/reconciled, not manually trusted
- Simulation and daily servicing are backend-owned
- AI competitors are normal `users` with `actor_type = 'AI'`

## Live Schema Snapshot

### Tables

Active tables expected in the game schema:

1. `season_clock`
2. `airports`
3. `aircraft_models`
4. `game_config`
5. `users`
6. `fleet_aircraft`
7. `route_assignments`
8. `bank_accounts`
9. `bank_transactions`
10. `loans`
11. `credit_scores`
12. `credit_score_history`
13. `achievements`
14. `game_events`
15. `world_tick_log`
16. `bot_profiles`
17. `bank_transaction_daily_summary`
18. `bank_transactions_archive`

### Triggers

Repo-local schema currently defines these live triggers:

1. `create_default_bank_account` on `users`
2. `fleet_reconcile_net_worth` on `fleet_aircraft`
3. `trg_user_hq_change` on `users`
4. `trg_bank_balance_reconcile_net_worth` on `bank_accounts`
5. `trg_loan_reconcile_net_worth` on `loans`

### Cron Jobs

Expected pg_cron jobs from baseline:

1. `skyward_world_tick` → `ensure_world_current()`
2. `skyward_compact_bank_transactions` → `compact_bank_transactions(false)`
3. `skyward_compact_world_tick_log` → `compact_world_tick_log(false)`

### Function Inventory

- `104` function definitions in baseline
- `85` unique function names
- User-facing wrapper overloads often delegate into internal SECURITY DEFINER overloads
- Do not assume `prosecdef = false` is a bug until wrapper/internal pairing is checked

## Important Recent Backend Work

### Finance / Credit Stabilization

- `08_finance_phase1_cash_movement.sql`
  Standardized cash movement through bank tables for financing and servicing paths.
- `09_finance_phase3_net_worth_consistency.sql`
  Restored net worth consistency via bank/fleet/loan reconciliation functions and triggers.
- `10_finance_phase4_credit_consistency.sql`
  Unified tier policy reads and credit contract behavior.
- `11_finance_phase5_lease_carrying_cost.sql`
  Added idle lease carrying-cost behavior.

### Actor Parity

- `12_actor_parity_route_economics.sql`
  Bot route economics aligned with player time fraction and demand/event factors.
- `13_actor_parity_daily_servicing.sql`
  Shared `process_actor_day_boundary()` for players and bots.
- `14_credit_policy_unification.sql`
  Bot borrowing routed through shared `take_loan()`.
- `15_acquisition_progression_rebalance.sql`
  Credit ladder, lease deposit gating, and score refresh rebalanced.

### Bot Humanization

- `16_bot_humanization_inertia.sql`
  Added bot distress states and action cooldown state in `bot_profiles`.
- `17_bot_decision_tick_alignment.sql`
  Re-aligned `process_world_tick()` so bot decisions run every tick and the cooldown design actually works.

## Verified Current State

- `flutter analyze`: clean
- `flutter test`: `239` passing
- Phase 5 bot cadence fix validated by ticking live DB and observing `bot_profiles` timestamps begin to populate
- Actor finance parity is much better than before, but mutation-path parity is not complete yet

## Re-opened Phase 1 Focus

Phase 1 is being re-opened deliberately. The old Phase 1 documentation is stale relative to migrations `08` through `17`.

The new Phase 1 goal is:

`Every live RPC, trigger, cron path, table, and column must be either proven used/tested or explicitly removed/wired.`

## Current Audit Findings To Carry Forward

### 1. Native DB coverage is still partial

Native SQL audits currently execute only a subset of the live RPC surface:

- Covered directly in SQL audit:
  - `purchase_aircraft`
  - `lease_aircraft`
  - `finance_aircraft`
  - `process_simulation_delta`
  - `process_player_simulation_to_time`
  - `calculate_user_net_worth`

- Not yet proven by native DB execution tests:
  - `configure_aircraft_seats`
  - `repair_aircraft`
  - `sell_aircraft`
  - `terminate_aircraft_lease`
  - `get_finance_snapshot`
  - `get_global_leaderboard`
  - `get_competitor_insights`
  - `get_owner_route_optimizer`
  - `save_airline_settings`
  - `reset_user_airline`
  - `delete_account` via Edge Function flow

Also important:

- `test/layer4_database/dart_integration/db_rpc_triggers_test.dart` is only a file-content harness, not real DB execution coverage.

### 2. Trigger coverage is mostly indirect

The repo has layer-4 audit harnesses, but no explicit trigger-by-trigger assertions by trigger name. Current trigger confidence is mostly behavioral and partial.

### 3. A stale frontend contract was removed, but the product gap remains

`FinanceGateway.getFinancialSnapshots()` no longer probes the non-existent
`get_financial_snapshots` RPC. It now explicitly returns a single current
`users.net_worth` snapshot point until a real historical finance snapshot
surface exists.

### 4. Trigger / auth proof gaps remain

- live DB now confirms `handle_new_auth_user()` is attached to `auth.users`, but that attachment is still repo-undeclared in the public migration set and should be documented as such

### 5. Native SQL coverage improved materially

- `take_loan`, `repay_loan`, `refinance_loan`, and `get_credit_report` are now covered in the rollback-style native SQL audit
- route CRUD (`create_route`, `assign_aircraft_to_route`, `update_route_frequency_and_price`, `delete_route`) is also covered in the same native audit
- `delete-account` is now live-proven by `test/layer4_database/native_audit/delete_account_e2e_audit.sh`, which exercises registration, auth login, Edge Function deletion, and post-delete row verification in both `public.users` and `auth.users`

### 6. Candidate dead / weakly wired schema

These are current candidates, not final delete orders:

- `world_tick_log.real_seconds_processed`
- `world_tick_log.game_seconds_processed`
- `fleet_aircraft.acquired_game_date`
- `game_config.unit`
- `bank_transactions_archive` consumer path
- most analytical columns in `bank_transaction_daily_summary`

### 7. Coverage weak spot: Bank feature

Routes, fleet, settings, leaderboard, and simulation have decent Dart-side coverage. Bank is the weakest live surface:

- bank cubit tests are largely placeholder-level
- bank gateway tests do not prove real loan RPC behavior
- native SQL now proves the core bank RPC lifecycle, but Dart-side bank tests are still weak

Recommended bias:

- delete if truly unused and not part of a near-term design
- wire if they support a real product/ops need
- keep only if they are backend-operational state, archival state, or imminent roadmap state

## Practical Working Rules

- Use `rg` first for text/file discovery
- Prefer remote Supabase verification for unstable facts, but expect pooler auth/circuit-breaker noise under load
- Treat `.opencode/PROMPT.md` and `.opencode/GRAND_PLAN.md` as the only agent-facing docs to keep current
- When changing backend contracts, update docs in the same workstream

## Success Bar For The Next Backend Pass

Phase 1 restart is done only when:

1. Every live RPC is either executed by native DB audit or deliberately classified and justified.
2. Every trigger and cron path has an explicit verification story.
3. Every table and column is classified as `wired`, `backend-only keep`, or `delete candidate`.
4. Stale frontend/backend contracts are removed.
5. Docs reflect the true post-`17` system, not the older pre-finance-pass shape.
