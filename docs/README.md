# Skyward Docs And Migrations

Last verified on 2026-06-22.

This folder is the maintenance record for Skyward's Supabase-backed runtime.
Use it as an operator guide, not as a chronological diary.

## Start Here

If you only open four files, open these:

1. [ai-handover.md](architecture/ai-handover.md)
2. [supabase-contracts.md](architecture/supabase-contracts.md)
3. [database.md](architecture/database.md)
4. [audit-queries.md](operations/audit-queries.md)

## Current Runtime State

Backend/runtime milestones already in place:
- shared season-clock world time
- deterministic daily simulation segmentation
- realtime UI reflection for `users`, `user_fleet`, `user_routes`, and `financial_ledger`
- finance snapshot RPC and retention/compaction audit surfaces
- owner/operator optimizer tooling
- Supabase Auth username-only flow via synthetic emails
- auth-bound gameplay RPC wrappers
- RLS on the app-facing read surface
- removal of the legacy custom-session auth system
- gateway pattern (7 gateways: Auth, Simulation, Fleet, Routes, Finance, Leaderboard, Settings)
- event system (`game_events` table with time-bounded fuel, demand, tax, and weather effects)
- notification panel, onboarding overlay, and help tooltip UI widgets
- financial snapshots for historical trend visualization
- hub-and-spoke bonus, airport congestion, and catch-up subsidy mechanics
- aviation depth: turnaround times, fare-class elasticity, crew costs, seasonal demand, maintenance milestones
- cargo revenue and non-linear aircraft degradation

## How To Use This Folder

Use docs by question:
- "What is the app/backend shape right now?"
  Open [ai-handover.md](architecture/ai-handover.md)
- "What RPCs or direct table reads does Flutter rely on?"
  Open [supabase-contracts.md](architecture/supabase-contracts.md)
- "What is the current database/security model?"
  Open [database.md](architecture/database.md)
- "How do I troubleshoot suspicious simulation behavior?"
  Open [simulation-guide.md](operations/simulation-guide.md)
- "What SQL should I run against live Supabase?"
  Open [audit-queries.md](operations/audit-queries.md)
- "How does the private owner/operator optimizer work?"
  Open [owner-tools.md](operations/owner-tools.md)
- "What is the current UI/UX design system?"
  Open [ui-design-system.md](architecture/ui-design-system.md)

## Documentation Set

Core maintenance docs:
- `architecture/ai-handover.md`
- `architecture/supabase-contracts.md`
- `architecture/database.md`

Operational/reference docs:
- `operations/simulation-guide.md`
- `operations/audit-queries.md`
- `operations/owner-tools.md`

UI/UX docs:
- `architecture/ui-design-system.md`

## Migration Bands

Apply migrations in numeric order.

High-level grouping:
- `01`-`18`
  Foundation schema, legacy auth, economy, reset, bots, maintenance
- `19`-`24`
  Regression audits and bot hardening
- `25`-`37`
  Realtime, balancing, replenishment, leaderboard fixes, offline-anchor fix,
  RPC write-boundary work
- `38`-`45`
  Season clock, scheduler, actor tick, world guardrails, deterministic daily simulation
- `46`-`61`
  Capacity/retention audits, compaction foundations, finance snapshot,
  route/cabin hardening, fleet disposal, owner/operator optimizer
- `62`-`68`
  Security hardening: Supabase Auth identity, auth bootstrap, RPC auth binding,
  RLS, and legacy custom-session removal
- `69`
  `financial_snapshots` UI read wiring
- `70`-`78`
  Security/race-condition fixes, route distance validation (Haversine), bot
  bankruptcy soft-delete, RLS policy fixes, performance indexes, sell-aircraft
  operation ordering, tail-number collision retry, password-hash column drop,
  game balance (competition, premium cabins, bot purchasing), event system
  (`game_events`), catch-up subsidy, hub bonus, `financial_snapshots` table,
  aviation depth (turnaround, fare-class elasticity, crew costs, seasonal
  demand, A/C-check milestones), cargo revenue, non-linear degradation

## Current Time Authority

Supabase owns production game time.

- `season_clock.current_game_time` is the shared season time
- `users.game_current_time` and `ai_competitors.game_current_time` are actor progress cursors
- `process_world_tick()` advances the season and actors
- Flutter observes backend time through realtime and `process_simulation_delta()`
- production Flutter does not locally advance game time

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
from get_database_size_report();
```

```sql
select *
from get_table_size_report()
limit 20;
```

```sql
select *
from get_world_tick_log_compaction_report();
```

```sql
select *
from get_financial_ledger_compaction_report();
```
