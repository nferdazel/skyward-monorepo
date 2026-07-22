# Skyward Docs

Last verified on 2026-07-22.

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

Completed plans:
- [plans/phase4-bot-realism-pass.md](plans/phase4-bot-realism-pass.md) — completed, migration `20260709150000`

## Migrations

The migration history has been consolidated into a single baseline file.

Current repo migration set:
- `00_baseline.sql` — consolidated schema (7191 lines, 312K)

This baseline was generated on 2026-07-22 by dumping the live Supabase schema
using `supabase db dump --linked --schema public`. It replaces the previous 58
individual migration files which are archived in `migrations_old/` for reference.

The baseline includes:
- 16 tables (achievements, aircraft_models, airports, bank_accounts, bank_transactions, bot_profiles, credit_score_history, credit_scores, fleet_aircraft, game_config, game_events, loans, route_assignments, season_clock, users, world_tick_log)
- 119 functions (all gameplay RPCs, simulation, finance, bot decision, credit scoring, etc.)
- 5 triggers (bank account creation, net worth reconciliation, HQ change sync)
- 26 indexes (performance-optimized for key query patterns)
- SECURITY DEFINER wrappers with auth-bound access control
- pg_cron jobs (world tick, bank transaction pruning, world tick log pruning)

### Historical migration reference

The previous58 migrations covered these phases:
1. **Baseline & critical fixes** (00-07): Schema establishment, security hardening
2. **Finance overhaul** (08-11): Bank-centric cash, net worth, credit, lease economics
3. **Actor parity** (12-18): Player/bot simulation alignment through shared helpers
4. **Ledger integrity** (19-27): Zero-amount guards, bankruptcy/repair parity
5. **Game clock alignment** (28-32): All ledger writes use in-game time
6. **Stability & consolidation** (33-34): Backend stability, tick configurability
7. **Bot realism & hardening** (35-41): Sub-function decomposition, behavioral improvements
8. **Targeted fixes & consolidation** (20260710 series): Wear cap, IFRS cleanup, security lockdown
  threshold, matching bot behavior
- `20260710210000`
  Fix stale cash in execute_bot_decisions: refresh v_bot_cash after each
  sub-function mutation (repair, fleet growth, route creation)
- `20260710220000`
  Consolidate process_player_simulation_to_time() into single clean function
  (replaces 9 DO-block patches across 6 migrations)
- `20260710230000`
  Consolidate process_all_bots_simulation_to_time() into single clean function
  (replaces DO-block patches from migrations 34 and 20260710150000)
- `20260710240000`
  Fix database constraints: bank_accounts default, loans.principal CHECK,
  NOT NULL on fleet_aircraft.user_id and bank_transactions.game_date,
  FK on bot_profiles.secondary_hub_iata, CHECK on route_assignments.status
  and bot_profiles.distress_stage, index on bot_profiles.archetype
- `20260710200000`
  Fix day boundary counter undercounting: consecutive_negative_days and
  recovery_streak_days now increment by CEIL(p_elapsed_days) instead of 1,
  making bankruptcy threshold reachable during catch-up
- `20260710250000`
  Fix performance indexes: add idx_bank_transactions_game_date, rebuild
  idx_users_active_bots to match actual query pattern

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
