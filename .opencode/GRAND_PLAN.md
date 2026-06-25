# Grand Plan — Skyward

## Status

Date: `2026-06-26`

This plan replaces the older stale version. It assumes the finance, actor-parity, and bot-humanization passes through migrations `08` to `17` already exist in the repo and must now be audited properly.

Current repo health:

- `flutter analyze` clean
- `flutter test` passing: `239`
- Migrations present: `00_baseline.sql` + `01` through `17`
- Current backend focus is no longer broad “rewrite everything”; it is `prove the live system is fully wired, tested, and professionally maintainable`

---

## Overall Objective

Build a backend and simulation stack that is:

1. stable
2. financially coherent
3. actor-consistent
4. operationally auditable
5. explicit about what is live vs stale

---

## Phase 1: Backend Proof Pass

### Goal

Every live RPC, trigger, cron path, table, and column must be:

1. tested or explicitly justified as indirectly verified
2. wired to a real consumer or clearly marked backend-only
3. documented accurately

This is a fresh Phase 1 pass. The older “Phase 1 complete” claim is no longer sufficient because the system changed materially after the finance and bot work.

### Why Phase 1 Is Re-opened

The backend is stronger than before, but there are still open proof gaps:

- native SQL audit coverage is partial
- trigger verification is mostly indirect
- some frontend/backend contracts are stale
- some schema looks weakly wired or archival-only
- docs no longer match migrations `08` through `17`

### Current Known Findings

#### Verified positives

- bank-centric cash model is in place
- net worth reconciliation logic exists
- player/bot daily servicing now shares a day-boundary path
- bot borrowing now routes through shared credit policy
- lease deposit gating is value-sensitive
- bot cooldowns/distress states exist and tick cadence now matches them

#### Verified proof gaps

- no native DB execution audit yet for route CRUD RPCs
- no native DB execution audit yet for repair/sell/terminate/configure fleet RPCs
- no native DB execution audit yet for account-deletion flow or several non-bank Tier 2 RPCs
- no explicit trigger-by-trigger assertions
- no explicit cron verification harness in tests
- current “DB RPC & Triggers Integration Harness” is not live DB execution; it only asserts SQL files exist and contain expected strings
- `delete_account` flow is live but not meaningfully covered end-to-end
- the auth-trigger story around `handle_new_auth_user` is now live-proven, but the attachment is still not declared by repo-local public migrations

#### Candidate dead / weakly wired schema

- `world_tick_log.real_seconds_processed`
- `world_tick_log.game_seconds_processed`
- `fleet_aircraft.acquired_game_date`
- `game_config.unit`
- `bank_transactions_archive` consumer path
- `bank_transaction_daily_summary` analytical columns beyond raw loading

---

### 1.1 Live Surface Inventory

- [x] Rebuild the authoritative list of live user-facing RPCs from:
  - app gateways
  - simulation paths
  - operational/admin routines that matter to production
- [x] Rebuild the authoritative list of live triggers
- [x] Rebuild the authoritative list of live cron jobs
- [x] Classify each function as:
  - user-facing RPC
  - internal helper
  - trigger function
  - cron/ops function
  - candidate dead function

#### Phase 1.1 Result

This inventory is now the baseline for all later coverage work.

##### Live user-facing RPC surface

Directly used by the Flutter app:

1. Routes
   - `create_route`
   - `assign_aircraft_to_route`
   - `update_route_frequency_and_price`
   - `delete_route`
   - `get_owner_route_optimizer`
2. Fleet
   - `purchase_aircraft`
   - `lease_aircraft`
   - `repair_aircraft`
   - `sell_aircraft`
   - `terminate_aircraft_lease`
   - `configure_aircraft_seats`
3. Bank / credit
   - `take_loan`
   - `finance_aircraft`
   - `repay_loan`
   - `refinance_loan`
   - `get_credit_report`
4. Simulation / finance
   - `process_simulation_delta`
   - `get_finance_snapshot`
   - `get_user_balance`
5. Leaderboard
   - `get_global_leaderboard`
   - `get_competitor_insights`
6. Settings
   - `save_airline_settings`
   - `reset_user_airline`

Special case:

- `get_financial_snapshots` used to be a stale frontend contract, but that probe has now been removed from the finance gateway.
- `delete_account` is part of the live user flow through the `delete-account` Edge Function, which then calls the `delete_account` RPC.

##### Internal wrapper convention

Many player-facing RPC names have two overload families:

1. wrapper overload resolved from auth context
2. internal overload with `p_user_id`

Do not flag these pairs as bugs by default. The correct test is whether the auth-facing wrapper delegates safely to the internal authoritative path.

##### Live trigger surface

Confirmed from repo migrations:

1. `create_default_bank_account` on `users`
2. `fleet_reconcile_net_worth` on `fleet_aircraft`
3. `trg_user_hq_change` on `users`
4. `trg_bank_balance_reconcile_net_worth` on `bank_accounts`
5. `trg_loan_reconcile_net_worth` on `loans`

Live auth-side nuance:

- `handle_new_auth_user` is live-verified as the `auth.users` bootstrap trigger target, but that attachment is not declared by the repo's public migrations and must stay documented as external-to-repo proof.

##### Live cron / ops surface

Confirmed from baseline scheduling:

1. `skyward_world_tick` → `ensure_world_current()`
2. `skyward_compact_bank_transactions` → `compact_bank_transactions(false)`
3. `skyward_compact_world_tick_log` → `compact_world_tick_log(false)`

##### Internal helper surface

Functions currently treated as internal engine/helper/ops surface include:

1. simulation helpers
   - `process_player_simulation_to_time`
   - `process_all_bots_simulation_to_time`
   - `process_actor_day_boundary`
   - `process_aircraft_financing_payments`
   - `process_loan_payments`
   - `process_credit_at_day_boundary`
   - `process_world_tick`
   - `execute_bot_decisions`
   - `spawn_bot`
2. finance primitives
   - `credit_bank_account`
   - `debit_bank_account`
   - `calculate_user_net_worth`
   - `calculate_credit_score`
   - `update_credit_score`
   - `resolve_credit_tier`
   - `get_credit_tier_policy`
   - `calculate_required_lease_deposit`
3. route / demand / capacity helpers
   - `calculate_airport_demand_factor`
   - `calculate_route_demand_multiplier`
   - `calculate_route_max_weekly_flights`
   - `calculate_route_expected_passengers`
   - `calculate_route_base_fare`
   - `calculate_effective_passenger_capacity`
4. config / auth / utility helpers
   - `get_config_numeric`
   - `get_config_int`
   - `get_config_text`
   - `get_config_jsonb`
   - `require_current_user_id`
   - `get_current_user_id`
   - `get_user_id_for_auth_uid`
   - `generate_tail_number`
   - `normalize_username`
   - `build_synthetic_auth_email`

##### Candidate dead-function inventory

These are candidates for Phase 2 review, not automatic deletions:

1. likely legacy bot-specific functions
   - `bot_take_loan`
   - `bot_finance_aircraft`
   - `process_bot_loan_payments`
2. weakly-consumed diagnostic / ops functions
   - `get_bot_health`
   - `get_database_size_report`
   - `get_table_size_report`
   - `get_world_tick_guardrail_report`
   - `get_world_tick_scheduler_health`
   - `get_world_tick_log_compaction_report`
3. weakly-consumed utility helpers
   - `get_fleet_commonality_discount`
   - `calculate_airport_congestion_factor`
   - `calculate_lease_termination_fee`
   - `get_hub_bonus_percentage`
   - `calculate_hub_bonus`

The rule for later phases:

- if it is not app-wired, not engine-wired, not cron-wired, not trigger-wired, and not part of a deliberate ops surface, it becomes a delete candidate

### 1.2 RPC Execution Coverage

- [x] Create a matrix of all live app-facing RPCs
- [x] Mark each RPC as:
  - native DB executed
  - mocked/unit covered only
  - not covered
- [ ] Expand layer-4 native SQL audits to execute missing critical RPCs

Priority RPC groups:

1. Route lifecycle
   - `create_route`
   - `assign_aircraft_to_route`
   - `update_route_frequency_and_price`
   - `delete_route`
2. Fleet lifecycle
   - `configure_aircraft_seats`
   - `repair_aircraft`
   - `sell_aircraft`
   - `terminate_aircraft_lease`
3. Credit / bank lifecycle
   - `take_loan`
   - `repay_loan`
   - `refinance_loan`
   - `get_credit_report`
   - `delete_account` path via Edge Function + RPC
4. Read RPCs that still matter operationally
   - `get_finance_snapshot`
   - `get_global_leaderboard`
   - `get_competitor_insights`
   - `get_owner_route_optimizer`
5. Settings RPCs
   - `save_airline_settings`
   - `reset_user_airline`

#### Phase 1.2 Result

Coverage status legend:

- `Native SQL`: executed by rollback-style SQL audit against the database
- `Dart`: covered only in mocked/unit/widget/integration app tests
- `None`: no meaningful coverage found yet

| RPC / Flow | App-wired | Dart coverage | Native SQL coverage | Current status |
|---|---|---|---|---|
| `create_route` | Yes | Yes | Yes | Well covered |
| `assign_aircraft_to_route` | Yes | Yes | Yes | Well covered |
| `update_route_frequency_and_price` | Yes | Yes | Yes | Well covered |
| `delete_route` | Yes | Yes | Yes | Well covered |
| `get_owner_route_optimizer` | Yes | No clear proof | No | Under-covered |
| `purchase_aircraft` | Yes | Yes | Yes | Well covered |
| `lease_aircraft` | Yes | Yes | Yes | Well covered |
| `repair_aircraft` | Yes | Yes | No | Dart-only |
| `sell_aircraft` | Yes | Yes | No | Dart-only |
| `terminate_aircraft_lease` | Yes | Yes | No | Dart-only |
| `configure_aircraft_seats` | Yes | Yes | No | Dart-only |
| `take_loan` | Yes | Placeholder / weak | Yes | SQL-covered, Dart weak |
| `finance_aircraft` | Yes | Placeholder / weak | Yes | SQL-only strong, Dart weak |
| `repay_loan` | Yes | Placeholder / weak | Yes | SQL-covered, Dart weak |
| `refinance_loan` | Yes | Placeholder / weak | Yes | SQL-covered, Dart weak |
| `get_credit_report` | Yes | Placeholder / weak | Yes | SQL-covered, Dart weak |
| `process_simulation_delta` | Yes | Yes | Yes | Well covered |
| `get_finance_snapshot` | Yes | Yes | No | Dart-only |
| `get_user_balance` | Yes | Indirect | No | Under-covered |
| `get_global_leaderboard` | Yes | Yes | No | Dart-only |
| `get_competitor_insights` | Yes | Yes | No | Dart-only |
| `save_airline_settings` | Yes | Yes | No | Dart-only |
| `reset_user_airline` | Yes | Yes | No | Dart-only |
| `delete_account` Edge Function → `delete_account` RPC | Yes | No clear proof | Yes | Live E2E-covered, Dart proof absent |

##### Important notes

1. `test/layer4_database/dart_integration/db_rpc_triggers_test.dart` does not execute DB contracts. It is only a file-content harness.
2. Bank is the weakest RPC surface right now.
   - `test/layer1_unit/bank/bank_cubit_test.dart` is still a placeholder
   - `test/layer1_unit/bank/bank_gateway_test.dart` is model parsing only
3. `get_financial_snapshots` remains outside this matrix because the stale probe was removed and it is not a live schema RPC.

##### Immediate native SQL expansion targets

Tier 1:

1. `take_loan`
2. `create_route`
3. `assign_aircraft_to_route`
4. `update_route_frequency_and_price`
5. `delete_route`

Tier 2:

1. `repair_aircraft`
2. `sell_aircraft`
3. `terminate_aircraft_lease`
4. `configure_aircraft_seats`
5. `save_airline_settings`
6. `reset_user_airline`
7. `get_finance_snapshot`
8. `get_global_leaderboard`
9. `get_competitor_insights`
10. `get_owner_route_optimizer`
11. `delete_account` flow

### 1.3 Trigger Verification

- [x] Verify `create_default_bank_account` explicitly
- [x] Verify `fleet_reconcile_net_worth` explicitly
- [x] Verify `trg_user_hq_change` explicitly
- [x] Verify `trg_bank_balance_reconcile_net_worth` explicitly
- [x] Verify `trg_loan_reconcile_net_worth` explicitly
- [x] Re-verify whether `handle_new_auth_user` is actually attached in live/auth schema or only documented

Expected output:

- one trigger verification matrix
- one native audit script or extension covering the behavior
- explicit pass/fail story for each trigger

#### Phase 1.3 Result

Current trigger verification matrix:

| Trigger | Table | Proof type | Evidence | Status |
|---|---|---|---|---|
| `create_default_bank_account` | `users` | Indirect native SQL | native audits insert into `users` and then rely on `bank_accounts` existing | Provisionally verified |
| `fleet_reconcile_net_worth` | `fleet_aircraft` | Indirect native SQL | net-worth audit path exercises fleet changes and recalculates net worth | Provisionally verified |
| `trg_user_hq_change` | `users` | Direct native SQL | system-wide audit updates `users.hq_airport_iata` and asserts purchased aircraft tail prefix re-syncs to Singapore (`9V-`) | Native proven |
| `trg_bank_balance_reconcile_net_worth` | `bank_accounts` | Indirect native SQL | finance audits mutate bank balance and then assert net-worth consistency | Provisionally verified |
| `trg_loan_reconcile_net_worth` | `loans` | Indirect native SQL | financing / debt audit path asserts net-worth consistency after loan creation | Provisionally verified |

Auth-related function status:

| Function | Trigger attachment proven in repo migrations? | Status |
|---|---|---|
| `handle_new_auth_user` | No | Live-verified attachment outside repo-local public migrations |

##### What “provisionally verified” means

These triggers are behaviorally covered by downstream assertions, but not yet by a dedicated trigger-specific native test. They are good enough to keep moving, but not good enough to call fully proven.

##### Remaining trigger nuance

1. `handle_new_auth_user`
   - live DB confirms the `auth.users` trigger attachment
   - repo-local public migrations still do not declare that auth-side trigger

### 1.4 Cron Verification

- [x] Verify `skyward_world_tick` target contract
- [x] Verify `skyward_compact_bank_transactions` target contract
- [x] Verify `skyward_compact_world_tick_log` target contract
- [x] Confirm schedules and expected side effects
- [ ] Decide whether cron proof belongs in SQL harness, manual ops doc, or both

#### Phase 1.4 Result

Repo-defined cron matrix:

| Job | Schedule | Command | Expected effect | Status |
|---|---|---|---|---|
| `skyward_world_tick` | `* * * * *` | `SELECT ensure_world_current()` | advances active season world time by running guarded world tick path | Repo-verified |
| `skyward_compact_bank_transactions` | `30 3 * * *` | `SELECT compact_bank_transactions(false)` | compacts historical bank transactions into summary/archive structures | Repo-verified |
| `skyward_compact_world_tick_log` | `30 3 * * *` | `SELECT compact_world_tick_log(false)` | compacts world tick logs | Repo-verified |

##### Verification boundary

What is verified now:

1. jobs are declared in baseline
2. target functions exist in schema
3. intended contracts are clear

What is not fully re-verified in this pass yet:

1. live `cron.job` rows in the linked remote project
2. most recent successful execution history
3. whether ops verification should be codified as SQL harness, runbook, or both

##### Current blocker

Live Supabase pooler queries have been intermittently hitting auth / circuit-breaker failures in this thread, so remote cron-state confirmation is still pending even though repo-defined cron contracts are clear.

### 1.5 Table / Column Wiring Audit

- [x] Classify every table as:
  - app-read wired
  - backend-write wired
  - ops/archive only
  - delete candidate
- [x] Classify every suspicious column as:
  - wired
  - backend-state keep
  - archival keep
  - delete candidate
- [x] Produce a delete/wire recommendation list with rationale

Specific review targets:

1. `bank_transaction_daily_summary`
   - confirm whether UI really needs all summary columns
2. `bank_transactions_archive`
   - confirm archival consumer path
3. `world_tick_log.real_seconds_processed`
4. `world_tick_log.game_seconds_processed`
5. `fleet_aircraft.acquired_game_date`
6. `game_config.unit`
7. `get_financial_snapshots` frontend fallback expectation

#### Phase 1.5 Result

##### Table wiring matrix

| Table | Classification | Notes |
|---|---|---|
| `season_clock` | backend-write wired | core world-time authority |
| `airports` | app-read wired | heavily consumed by routes/settings/planning |
| `aircraft_models` | app-read wired | heavily consumed by fleet/bank/planning |
| `game_config` | backend-write wired | runtime config source; app has limited direct reads |
| `users` | app-read + backend-write wired | primary actor state |
| `fleet_aircraft` | app-read + backend-write wired | core fleet state |
| `route_assignments` | app-read + backend-write wired | core route state |
| `bank_accounts` | app-read + backend-write wired | canonical cash store |
| `bank_transactions` | app-read + backend-write wired | canonical money trail |
| `loans` | app-read + backend-write wired | core debt state |
| `credit_scores` | app-read + backend-write wired | current score surface |
| `credit_score_history` | app-read wired | limited but real bank feature use |
| `achievements` | app-read + backend-write wired | normal gameplay table |
| `game_events` | backend-write wired | simulation event engine |
| `world_tick_log` | ops/backend-only keep | low app wiring, but useful for scheduler health and audit |
| `bot_profiles` | backend-write wired | active bot state/cooldowns/distress metadata |
| `bank_transaction_daily_summary` | app-read weak + backend-write wired | UI consumes table, but most columns are not clearly surfaced |
| `bank_transactions_archive` | archive-only keep candidate | backend compaction target; no app/test consumer found |

##### Suspicious column matrix

| Table.Column | Current read | Recommendation | Rationale |
|---|---|---|---|
| `world_tick_log.real_seconds_processed` | No clear consumer | Delete candidate | present in schema but no wiring evidence found |
| `world_tick_log.game_seconds_processed` | No clear consumer | Delete candidate | present in schema but no wiring evidence found |
| `fleet_aircraft.acquired_game_date` | backend logic only | Keep | used in aircraft sale aging / depreciation logic |
| `game_config.unit` | no runtime consumer found | Delete or doc-only keep | currently metadata only; no app/runtime dependency found |
| `bank_transaction_daily_summary.transaction_count` | no clear UI proof | Wire or delete | summary table is used, but this specific field lacks consumption proof |
| `bank_transaction_daily_summary.total_amount` | no clear UI proof | Wire or delete | same issue |
| `bank_transaction_daily_summary.total_debits` | no clear UI proof | Wire or delete | same issue |
| `bank_transaction_daily_summary.total_credits` | no clear UI proof | Wire or delete | same issue |
| `bank_transaction_daily_summary.first_balance` | no clear UI proof | Wire or delete | same issue |
| `bank_transaction_daily_summary.last_balance` | no clear UI proof | Wire or delete | same issue |
| `bank_transaction_daily_summary.first_game_date` | no clear UI proof | Wire or delete | same issue |
| `bank_transaction_daily_summary.last_game_date` | no clear UI proof | Wire or delete | same issue |
| `bank_transaction_daily_summary.compacted_at` | no clear UI proof | backend-state keep | operationally reasonable even if UI does not use it |
| `bank_transactions_archive.archived_at` | no app proof | archival keep | valid archival metadata if archive path is retained |

##### Concrete recommendations

1. Keep:
   - `fleet_aircraft.acquired_game_date`
   - `world_tick_log`
   - `bot_profiles`
   - `bank_transactions_archive` for now, but explicitly classify it as archive/ops-only
2. Re-audit before delete:
   - `world_tick_log.real_seconds_processed`
   - `world_tick_log.game_seconds_processed`
   - `game_config.unit`
3. Force a product decision:
   - either fully use `bank_transaction_daily_summary` analytical columns in finance UI / reporting
   - or collapse the table to the subset actually needed
4. Cleanup target outside schema:
   - remove or formalize `get_financial_snapshots` fallback contract in finance gateway

### 1.6 Contract Drift Cleanup

- [x] Remove or formalize stale frontend contract assumptions
- [x] Resolve the `get_financial_snapshots` fallback smell
- [x] Re-check wrapper/internal RPC conventions so docs do not falsely flag valid overload patterns as bugs

#### Phase 1.6 Result

Completed:

1. Removed the phantom `get_financial_snapshots` RPC probe from
   `SupabaseFinanceGateway`.
2. Kept finance history behavior stable by using the current `users` net-worth
   snapshot directly until a real historical RPC/table surface exists.
3. Updated docs so they no longer present the `handle_new_auth_user` auth
   trigger attachment as a proven fact from public repo migrations alone.
4. Explicitly documented wrapper/internal RPC overload conventions in Phase
   1.1 so false positives are less likely in later audits.

Still pending outside this cleanup:

1. product decision on whether a real historical finance snapshot contract
   should exist

### 1.7 Verification Gate

Phase 1 can close only when all of these are true:

- [x] `flutter analyze` passes
- [x] `flutter test` passes
- [x] live RPC coverage matrix exists and is current
- [x] trigger verification matrix exists and is current
- [x] cron verification notes exist and are current
- [x] table/column wiring matrix exists and is current
- [x] stale contracts are removed or documented

#### Phase 1.7 Result

Phase 1 documentation and classification work is complete.

What is true now:

1. repo health is green
   - `flutter analyze` clean
   - `flutter test` passing (`239`)
2. the live-surface inventory exists
3. the RPC coverage matrix exists
4. the trigger verification matrix exists
5. the cron verification notes exist
6. the table/column wiring matrix exists
7. the `get_financial_snapshots` stale contract was removed
8. docs now describe `handle_new_auth_user` as live-proven but repo-undeclared

What is still intentionally unresolved:

1. native SQL execution coverage is still incomplete
2. auth-coupled bank/account flows still lack full native execution proof
3. live auth-trigger attachment for `handle_new_auth_user` is proven in the linked DB, but not declared in repo-local public migrations
4. several schema items are still only candidates, not final delete decisions

Conclusion:

- Phase 1 as an audit / proof pass is complete enough to hand off into
  execution work.
- Phase 2 should now be treated as the implementation backlog generated by
  Phase 1, not as a fresh exploratory audit.

---

## Phase 2: Cleanup / Hardening Pass

### Goal

Remove what should not exist, and wire what should exist.

### Scope

- [ ] add missing native SQL coverage for Tier 1 RPCs
- [x] add direct trigger proof for `trg_user_hq_change`
- [x] decide and resolve auth-trigger truth for `handle_new_auth_user`
- [ ] delete confirmed dead columns
- [ ] delete confirmed dead functions
- [ ] delete confirmed dead tables or archive paths if truly unnecessary
- [ ] tighten docs after cleanup lands

### Execution Backlog

#### Phase 2A: Coverage hardening

1. Extend native SQL audit for:
   - [x] `take_loan`
   - [x] `repay_loan`
   - [x] `refinance_loan`
   - [x] `get_credit_report`
   - [x] `create_route`
   - [x] `assign_aircraft_to_route`
   - [x] `update_route_frequency_and_price`
   - [x] `delete_route`
2. Add direct trigger test for:
   - [x] `trg_user_hq_change`
3. Add end-to-end delete-account proof:
   - Edge Function path
   - `delete_account` RPC side effect

#### Phase 2A Progress

Completed in this pass:

1. Updated `test/layer4_database/native_audit/supabase_audit_test.sql` so it
   matches the live schema again.
   - removed stale `users.cash` assumptions
   - removed stale `airports.airport_tax` assumptions
2. Added native SQL coverage for:
   - `take_loan(p_user_id, ...)`
   - `create_route(p_user_id, ...)`
   - `assign_aircraft_to_route(p_user_id, ...)`
   - `update_route_frequency_and_price(p_user_id, ...)`
   - `delete_route(p_user_id, ...)`
3. Updated `test/layer4_database/native_audit/finance_credit_regression_test.sql`
   so its financing model selection respects the live Standard-tier financing
   ladder.
4. Re-ran both native SQL audit scripts successfully against the linked remote
   DB.
5. Added direct native proof for `trg_user_hq_change` by updating HQ and
   asserting tail-number prefix re-sync.
6. Confirmed via linked live DB inspection that `handle_new_auth_user()` is
   attached to `auth.users`, while also confirming that this attachment is not
   represented in the repo's public migration set.
7. Added auth-session harness coverage for `get_credit_report`,
   `repay_loan`, and `refinance_loan` by binding the audit user to an
   otherwise-unmapped `auth.users` row inside the rollback transaction.
8. Added and executed `test/layer4_database/native_audit/delete_account_e2e_audit.sh`
   to prove the real Edge Function path from registration through auth login,
   account deletion, and zero-row verification in both `public.users` and
   `auth.users`.

Still pending in Phase 2A:

1. none

Reason these remain pending:

- Phase 2A is now complete; remaining work moves to later phases

#### Phase 2B: Bank test quality

1. Replace placeholder `BankCubit` test
2. Upgrade `bank_gateway_test.dart` beyond model parsing
3. Prove bank RPC behavior with realistic response contracts

#### Phase 2C: Schema cleanup decisions

1. Decide fate of:
   - `world_tick_log.real_seconds_processed`
   - `world_tick_log.game_seconds_processed`
   - `game_config.unit`
2. Decide whether `bank_transactions_archive` stays as archive/ops-only
3. Decide whether to fully wire or slim down
   `bank_transaction_daily_summary`

#### Phase 2D: Auth truth cleanup

1. Keep docs explicit that `handle_new_auth_user` is live-verified
2. Keep docs equally explicit that the auth-side trigger attachment is not
   declared by the repo's public migrations

### Exit Criteria

- [ ] no confirmed dead schema remains
- [ ] no stale RPC expectations remain in frontend
- [ ] no “keep for now” item remains without a written reason
- [x] no unproven auth-trigger assumptions remain in docs

---

## Phase 3: Actor Parity Hardening

### Goal

Players and bots should be subject to the same economic engine and mutation rules unless asymmetry is explicitly game-designed.

### Known open issue

Financial policy parity improved a lot, but mutation-path parity is still incomplete. Bot logic still performs some direct inserts/updates rather than always going through the same high-level action contracts as player flows.

### Scope

- [ ] identify bot-only mutation shortcuts
- [ ] decide which should be replaced with shared internal action helpers
- [ ] preserve game feel while reducing hidden rules divergence

### Exit Criteria

- [ ] bot and player action families share the same authoritative mutation layer where appropriate
- [ ] remaining asymmetries are intentional and documented

---

## Phase 4: Bot Realism Pass

### Goal

Make bots feel less scripted and more operator-like without breaking balance.

### Current state

Bot cadence and distress states are materially better after migrations `16` and `17`, but strategy still relies heavily on archetype hard-coding, HQ bias, and limited route-by-route memory.

### Scope

- [ ] commercial memory per route
- [ ] smarter route trim / growth pacing
- [ ] less deterministic fleet preference
- [ ] stronger maintenance and distress behavior
- [ ] more human-looking network evolution

### Exit Criteria

- [ ] bot decisions look consistent over time
- [ ] fewer hyper-reactive or obviously scripted behaviors
- [ ] no major regressions in finance stability

---

## Phase 5: Documentation Discipline

### Goal

Keep only high-signal docs that match the codebase.

### Rules

- `.opencode/PROMPT.md` and `.opencode/GRAND_PLAN.md` are canonical for agent context
- stale docs are defects
- every major backend pass updates these docs in the same workstream

### Ongoing checklist

- [ ] update docs whenever backend contracts change
- [ ] remove contradictory notes immediately
- [ ] avoid aspirational statements that are not yet true

---

## Immediate Next Move

Execute Phase 1.2 through 1.5 in that order:

1. complete live RPC coverage matrix
2. complete trigger verification matrix
3. complete table/column wiring matrix
4. turn findings into concrete cleanup tasks
