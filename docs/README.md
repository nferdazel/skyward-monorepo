# Skyward Docs

Last verified on 2026-06-26.

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
- live `auth.users -> handle_new_auth_user()` bootstrap trigger, proven in the linked DB
- shared season clock in `season_clock`
- deterministic daily simulation boundaries for player and bot processing
- route/fleet/bank/settings writes go through RPCs
- realtime reflection on `users`, `fleet_aircraft`, `route_assignments`,
  `bank_transactions`, `achievements`, and `loans`
- bank / credit / financing system with shared player-facing and bot-facing policy
- rollback-style native SQL audits for fleet, routes, finance, and core bank RPCs
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

High-level grouping:
- `00`-`07`
  Baseline schema plus early correctness fixes
- `08`-`11`
  Finance stabilization, bank-centric cash, net-worth reconciliation, lease carrying cost
- `12`-`18`
  Actor parity, servicing, and bot decision-path hardening
- `19`-`25`
  Ledger integrity, zero-amount guardrails, player sync safety, bankruptcy parity, shared repair mechanics, finance snapshot contract truthfulness, and missing trigger attachment cleanup

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
