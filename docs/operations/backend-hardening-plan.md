# Skyward Backend Hardening Plan

Last verified on 2026-06-26.

This document turns the current backend scorecard into an execution backlog.
It is intentionally phase-based, with concrete scope, checks, and exit
criteria.

## Goal

Raise backend confidence from "strong but drift-prone" to "strong and
defensible under regression".

Current emphasis:
- increase proof quality
- reduce bot/player drift
- remove misleading fallback or stale contract claims
- keep docs and live runtime behavior aligned

## Current Score Snapshot

| Area | Score | Risk |
|---|---:|---|
| Simulation core | 8.5/10 | Medium |
| World tick / scheduler | 8.0/10 | Medium |
| Bank / ledger | 8.5/10 | Low |
| Credit / loans | 8.5/10 | Low |
| Fleet / routes mutation authority | 8.0/10 | Medium |
| Bot / player parity | 7.5/10 | High |
| Finance historical surfaces | 7.0/10 | High |
| Auth / ownership / RLS | 8.0/10 | Medium |
| Ops / audit surfaces | 8.0/10 | Medium |
| Tests / proof coverage | 8.0/10 | Medium |
| Docs / contract accuracy | 7.5/10 | Medium-High |

## Execution Order

1. Phase 1: Proof Hardening
2. Phase 2: Bot / Player Parity Cleanup
3. Phase 3: Historical Read-Surface Honesty
4. Phase 4: Realtime and Freshness Audit
5. Phase 5: Repo / Live Proof Closure
6. Phase 6: Ongoing Docs Discipline

## Phase 1: Proof Hardening

### Goal

Increase confidence in backend behavior under regression, especially around
simulation, finance, and mutation side effects.

### Scope

- native SQL behavioral audits
- invariants for world tick and player reconciliation
- ledger invariants that are easy to silently regress
- parity-sensitive mutation side effects

### Checklist

- [x] add world-tick invariants to SQL audit coverage
- [x] add player catch-up invariants to SQL audit coverage
- [x] assert no-op sync paths do not emit cash or ledger side effects
- [x] assert route/fleet mutations produce the expected finance side effects
- [x] assert credit/loan lifecycle leaves the expected ledger and balance state
- [x] execute app-facing read and settings RPCs in native SQL audit coverage
- [x] convert placeholder or shallow backend-related tests into real assertions

### Suggested Deliverables

- `test/layer4_database/native_audit/supabase_audit_test.sql`
- `test/layer4_database/native_audit/finance_credit_regression_test.sql`
- targeted Flutter contract tests where SQL behavior is mirrored into parsing or
  cubit assumptions

### Exit Criteria

- core simulation and finance mutations have behavioral audit coverage
- app-facing read and settings RPCs are exercised against the real database
- no-op and edge-case paths are asserted, not assumed
- known recent regressions are permanently covered by tests

### Current Progress

- native SQL audit now executes app-facing read surfaces:
  `get_user_balance`, `get_finance_snapshot`, `get_global_leaderboard`,
  `get_competitor_insights`, and `get_owner_route_optimizer`
- native SQL audit now executes auth-bound settings wrappers:
  `save_airline_settings` and `reset_user_airline`
- reset coverage now proves deletion/reset semantics for fleet, routes, loans,
  bank history, onboarding state, and default operating cash restoration
- live contract drift around `get_finance_snapshot.active_route_count` has now
  been removed by making the function count only active route rows
- direct trigger proof now covers `create_default_bank_account`,
  `fleet_reconcile_net_worth`, `trg_bank_balance_reconcile_net_worth`,
  `trg_loan_reconcile_net_worth`, and `trg_user_hq_change`
- the linked runtime exposed a real repo gap during this pass:
  `trg_bank_balance_reconcile_net_worth()` existed as a function, but the
  trigger attachment on `bank_accounts` was missing until migration `25`

## Phase 2: Bot / Player Parity Cleanup

### Goal

Make shared game rules actually flow through shared mutation paths wherever
parity is intended.

### Scope

- route lifecycle mutations
- fleet acquisition / disposal side effects
- servicing and finance side effects
- any remaining asymmetry that changes economy outcomes

### Checklist

- [ ] map all player mutation entrypoints against bot mutation entrypoints
- [ ] classify each asymmetry as intentional or accidental
- [ ] refactor accidental asymmetries through shared helpers
- [ ] add regression coverage for each parity fix
- [ ] document intentional asymmetries explicitly

### Current Progress

- player and bot bankruptcy paths were proven divergent in live repo code:
  bot bankruptcy grounded fleet and defaulted loans, while player bankruptcy
  only flipped `users.operational_status` and cancelled routes
- `apply_actor_bankruptcy_state(user_id)` is now the shared helper target for
  both paths, reducing another economy-affecting rule fork
- `process_actor_day_boundary()` now also routes 30-day negative-cash
  bankruptcy through that same helper, so bankruptcy side effects do not vary
  by entrypoint
- daily loan servicing already runs through shared `process_actor_day_boundary()`;
  the remaining meaningful servicing drift was repair recovery, not collections
- player `repair_aircraft()` and bot paid repair recovery now share one
  internal repair helper for pricing, ledger writes, and fleet-state updates
- native SQL audit coverage now asserts that player bankruptcy also grounds
  fleet, defaults active loans, and cancels active routes
- native SQL audit coverage now also asserts player repair writes one
  maintenance ledger row, restores `condition = 100`, and reactivates the
  airframe
- this closes the currently proven accidental asymmetries in bankruptcy and
  repair side effects; the remaining Phase 2 task is documenting intentional
  bot-only behavior so future work does not "fix" designed differences

### Intentional Asymmetries

- bot distress gating and cooldown timers remain bot-only decision policy
  metadata, not shared player mutation rules
- bot autonomous action timing remains world-tick driven; player actions remain
  explicit RPC-triggered mutations from the client
- bot route growth, pricing posture, and fleet doctrine remain archetype-driven
  strategy differences, as long as the underlying mutation side effects still
  flow through shared authoritative helpers where parity is intended

### Exit Criteria

- shared rules use shared helper layers where appropriate
- remaining differences are intentional, documented, and justified

## Phase 3: Historical Read-Surface Honesty

### Goal

Stop implying that historical surfaces exist when the live contract is
fallback-based, partial, or backend-only.

### Scope

- finance historical charting
- any UI or docs that imply unavailable historical tables or RPCs
- read surfaces that still rely on temporary fallback semantics

### Checklist

- [ ] audit all frontend history views against live public schema
- [ ] decide per surface: implement, degrade honestly, or remove claim
- [ ] remove stale references to phantom tables, RPCs, or dropped features
- [ ] document any temporary fallback as temporary, not product truth

### Current Known Targets

- finance historical net-worth charting
- any leftover wording around dropped rank-history surfaces

### Current Progress

- the stale Flutter read path for `bank_transaction_daily_summary` has now
  been removed
- dormant bank compaction surface has now been removed by migration `27`:
  - cron job `skyward_compact_bank_transactions`
  - function `compact_bank_transactions(boolean)`
  - config key `bank_txn_raw_retention_days`
  - tables `bank_transaction_daily_summary` and `bank_transactions_archive`
- linked live proof confirms both compaction tables are absent after the
  migration; some additional verification queries still hit intermittent
  Supabase pooler `ECIRCUITBREAKER` / temp-role-auth failures, but the removal
  migration itself executed successfully against the linked DB
- retention now returns in a simpler form through migration `28`:
  - cron job `skyward_prune_bank_transactions`
  - function `prune_bank_transactions(boolean)`
  - config key `bank_txn_raw_retention_game_days`
  - delete-only pruning against `bank_transactions.game_date`

### Exit Criteria

- no user-facing or maintainer-facing doc claims a historical surface that does
  not actually exist
- fallback behavior is explicit in docs and code comments

## Phase 4: Realtime and Freshness Audit

### Goal

Reduce stale-state behavior after successful mutations or background
reconciliation.

### Scope

- realtime subscriptions
- post-mutation reload flows
- silent refresh paths
- feature-specific freshness gaps outside Bank

### Checklist

- [x] audit refresh behavior for fleet
- [x] audit refresh behavior for routes
- [x] audit refresh behavior for finance overview/history
- [x] verify mutation success paths trigger enough refetch or realtime updates
- [ ] add tests where stale-state regressions are likely

### Exit Criteria

- successful mutations are reflected consistently without manual tab hopping
- realtime is treated as freshness support, not as a fragile substitute for
  explicit reload logic

### Current Result

- fleet-side aircraft actions now force authoritative follow-up refresh for
  simulation, bank, and finance state
- bank loan / refinance / financing success paths now trigger the same
  authoritative refresh sequence
- settings save now refreshes profile-owned consumers (`AuthCubit`,
  `SimulationCubit`, fleet, routes) rather than relying on delayed reflection
- airline reset now reloads bank and finance state in addition to simulation,
  fleet, and routes

## Phase 5: Repo / Live Proof Closure

### Goal

Close the gap between what the repo declares and what the linked live runtime
proves.

### Scope

- auth bootstrap trigger attachment
- repo vs live function declarations
- operational assumptions currently proven only by manual live checks

### Checklist

- [ ] enumerate all live-proven but repo-undeclared behaviors
- [ ] decide whether to migrate, document, or intentionally keep external
- [ ] close auth bootstrap declaration gap where feasible
- [ ] verify docs do not overstate what public migrations alone guarantee

### Exit Criteria

- maintainers can tell which truths come from migrations, which from live
  environment state, and which are intentionally external

## Cleanup Notes

Recent cleanup landed:

- migration `26_drop_dead_legacy_helpers.sql` removes dead legacy helpers that
  were no longer referenced by the app surface or the latest bot engine:
  `bot_take_loan`, `bot_finance_aircraft`, `process_bot_loan_payments`,
  `get_fleet_commonality_discount`, and `get_hub_bonus_percentage`

## Phase 6: Ongoing Docs Discipline

### Goal

Prevent drift from reappearing after backend or contract work.

### Scope

- architecture docs
- operations docs
- audit query docs
- handover docs

### Checklist

- [ ] update docs in the same workstream as backend changes
- [ ] remove stale claims immediately instead of preserving historical wording
- [ ] keep audit queries aligned to live field and function names
- [ ] keep clock-domain notes current when adding new timestamp surfaces

### Exit Criteria

- docs are treated as runtime maintenance artifacts, not historical notes
- contract drift is caught during work, not weeks later

## Recommended Verification Per Phase

### Baseline

```bash
flutter analyze
flutter test
```

### Backend / Runtime

```bash
SUPABASE_DISABLE_TELEMETRY=1 supabase db query --linked -f test/layer4_database/native_audit/supabase_audit_test.sql
SUPABASE_DISABLE_TELEMETRY=1 supabase db query --linked -f test/layer4_database/native_audit/finance_credit_regression_test.sql
test/layer4_database/native_audit/delete_account_e2e_audit.sh
```

### Targeted Live Checks

- `get_world_tick_guardrail_report()`
- `get_world_tick_scheduler_health()`
- audit queries in [audit-queries.md](audit-queries.md)

## Practical Prioritization

If time is limited, do these first:

1. Phase 1
2. Phase 2
3. Phase 3

That sequence gives the highest confidence gain per unit effort.

## Definition of Done

This hardening pass is in good shape when:

- backend behavior is proven by tests more often than by assumption
- bot/player shared rules do not silently diverge
- fallback or partial read surfaces are clearly labeled
- repo docs and live runtime stop contradicting each other
