# Skyward Docs

Last verified on 2026-07-09.

This folder is the current maintenance record for Skyward's live runtime.
It is intentionally organized by operational question, not by historical phase.

## Start Here

If you only open four files, open these:

1. [architecture/ai-handover.md](architecture/ai-handover.md)
2. [architecture/supabase-contracts.md](architecture/supabase-contracts.md)
3. [architecture/database.md](architecture/database.md)
4. [operations/audit-queries.md](operations/audit-queries.md)

## Current Runtime State

Live runtime characteristics:
- Flutter frontend with Cubit-only app state
- Supabase/Postgres authoritative backend
- bank-centric cash model:
  - `bank_accounts` is canonical cash
  - `bank_transactions` is canonical money movement
- auth-bound gameplay RPC wrappers using `auth.uid()`
- username-only auth UX backed by synthetic auth emails
- live `auth.users -> handle_new_auth_user()` bootstrap trigger (declared in
  migration `20260709180000_declare_auth_trigger.sql`)
- shared season clock in `season_clock`
- deterministic daily simulation boundaries for player and bot processing
- route/fleet/bank/settings writes go through RPCs
- realtime reflection on `users`, `fleet_aircraft`, `route_assignments`,
  `bank_transactions`, and `loans`
- realtime is a freshness aid, not the sole consistency mechanism; the Flutter
  runtime now also performs explicit post-mutation resyncs for fleet, routes,
  bank, finance, and settings flows
- bank / credit / financing system with shared player-facing and bot-facing policy
- rollback-style native SQL audits for fleet, routes, finance, settings, core
  bank RPCs, and direct trigger proof
- live-proven `delete-account` Edge Function path with end-to-end deletion audit

## Documentation Layout

Architecture docs:
- [architecture/overview.md](architecture/overview.md)
- [architecture/ai-handover.md](architecture/ai-handover.md)
- [architecture/database.md](architecture/database.md)
- [architecture/supabase-contracts.md](architecture/supabase-contracts.md)
- [architecture/ui-design-system.md](architecture/ui-design-system.md)

Operations docs:
- [operations/audit-queries.md](operations/audit-queries.md)
- [operations/backend-hardening-plan.md](operations/backend-hardening-plan.md)
- [operations/simulation-guide.md](operations/simulation-guide.md)
- [operations/owner-tools.md](operations/owner-tools.md)

Standards:
- [standards/maintainer-standard.md](standards/maintainer-standard.md)
- [../SECURITY.md](../SECURITY.md)

## Migrations

Apply migrations in numeric order.

Current repo migration set:
- `00_baseline.sql`
- `01_critical_fixes.sql`
- `02_fix_stale_refs.sql`
- `03_fix_search_path.sql`
- `04_critical_fixes_v2.sql`
- `05_bot_fixes.sql`
- `06_simulation_credit_fixes.sql`
- `07_data_fixes.sql`
- `08_finance_phase1_cash_movement.sql`
- `09_finance_phase3_net_worth_consistency.sql`
- `10_finance_phase4_credit_consistency.sql`
- `11_finance_phase5_lease_carrying_cost.sql`
- `12_actor_parity_route_economics.sql`
- `13_actor_parity_daily_servicing.sql`
- `14_credit_policy_unification.sql`
- `15_acquisition_progression_rebalance.sql`
- `16_bot_humanization_inertia.sql`
- `17_bot_decision_tick_alignment.sql`
- `18_actor_parity_mutation_helpers.sql`
- `19_finance_ledger_integrity.sql`
- `20_credit_and_zero_amount_guardrails.sql`
- `21_player_sim_zero_interval_guard.sql`
- `22_actor_bankruptcy_parity.sql`
- `23_actor_repair_helper_parity.sql`
- `24_finance_snapshot_active_routes.sql`
- `25_attach_bank_balance_net_worth_trigger.sql`
- `26_drop_dead_legacy_helpers.sql`
- `27_drop_bank_transaction_compaction.sql`
- `28_add_bank_transaction_retention.sql`
- `29_sync_finance_aircraft_game_time.sql`
- `30_add_loan_originated_game_date.sql`
- `31_use_game_clock_for_loan_mutations.sql`
- `32_keep_lease_termination_on_exact_game_time.sql`
- `33_backend_stability_fixes.sql`
- `34_tick_configurability_and_fixes.sql`
- `20260709143000_actor_parity_hardening.sql`

High-level grouping:
- `00`-`07`
  Baseline schema plus early correctness fixes
- `08`-`11`
  Finance stabilization, bank-centric cash, net-worth reconciliation, lease carrying cost
- `12`-`18`
  Actor parity, servicing, and bot decision-path hardening
- `19`-`32`
  Ledger integrity, zero-amount guardrails, player sync safety, bankruptcy parity, shared repair mechanics, finance snapshot contract truthfulness, missing trigger attachment cleanup, and dead helper removal
  plus removal of the dormant bank compaction surface and reintroduction of a
  simpler game-date-based ledger retention policy, plus finance-aircraft
  game-time sync, plus in-game loan origination chronology, plus repayment /
  lease-termination chronology fixes to keep player-facing ledger rows on the
  exact shared game clock
- `33`
  Backend stability: critical `refinance_loan()` regression fix, per-bot error
  handling in `execute_bot_decisions()`, migration of hardcoded magic numbers
  to `game_config`
- `34`
  Tick configurability: `tick_interval_seconds` and `max_catchup_ticks` via
  `game_config`, day-boundary payment loop for multi-week catch-ups, human
  `finance_aircraft` gets Regional-archetype default seats
- `20260709143000`
  Actor parity hardening: restores bankruptcy parity regression from migration
  33, creates shared helpers for `sell_aircraft`, `terminate_aircraft_lease`,
  and `assign_aircraft_to_route` so all fleet/route/bank mutation paths are
  unified between player and bot
- `20260709150000`
  Bot realism pass: shared `get_route_performance()` function, smart route
  deletion based on commercial performance, route optimization (aircraft
  reassignment), secondary hub exploration, fleet diversity, lowered purchase
  threshold, competitive pricing response, desperate stage recovery, active
  loan repayment
- `20260709160000`
  Fix world_tick_log compaction: pg_cron fails to execute DELETE through
  `compact_world_tick_log(false)` — add simpler `prune_world_tick_log()`
  wrapper with no parameters; update cron job to use it
- `20260709170000`
  Fix round(double precision, integer) bug in get_route_performance() caused by
  type propagation from distance_km; drop 4 confirmed dead functions
  (compact_world_tick_log, get_world_tick_log_compaction_report, get_config_text,
  calculate_effective_passenger_capacity)
- `20260709180000`
  Declare auth.users bootstrap trigger in repo (previously live-only, not declared
  in public migrations)
- `20260709190000`
  Refactor execute_bot_decisions() into 7 focused sub-functions:
  bot_evaluate_distress, bot_handle_repair, bot_handle_route_lifecycle,
  bot_handle_fleet_growth, bot_handle_route_creation, bot_handle_pricing,
  bot_handle_financial
- `20260709200000`
  Fix get_competitor_insights() to use canonical calculate_user_net_worth()
  instead of stale users.net_worth column; add live fleet_size and route_count

## Standard Verification

```bash
flutter analyze
flutter test
```

## Standard Live Checks

```sql
select *
from get_world_tick_guardrail_report();
```

```sql
select *
from get_world_tick_scheduler_health();
```

Use `get_world_tick_scheduler_health()` as the primary live proof that the
`skyward_world_tick` scheduler job exists and is active. Direct linked queries
to `cron.job` / `cron.job_run_details` may still be useful for ops, but they
can be blocked intermittently by pooler auth/circuit-breaker behavior.

```sql
select *
from get_database_size_report();
```

```sql
select *
from get_table_size_report()
limit 20;
```

## Native / E2E Audits

Rollback-style native SQL:

```bash
SUPABASE_DISABLE_TELEMETRY=1 supabase db query --linked -f test/layer4_database/native_audit/supabase_audit_test.sql
SUPABASE_DISABLE_TELEMETRY=1 supabase db query --linked -f test/layer4_database/native_audit/finance_credit_regression_test.sql
```

Delete-account end-to-end audit:

```bash
test/layer4_database/native_audit/delete_account_e2e_audit.sh
```

## Maintenance Rule

Stale docs are defects.
If a backend contract, table name, trigger story, or audit status changes, the
matching docs must be updated in the same workstream.
