# Skyward AI Handover

Last verified against code on 2026-06-27.

## Current shape

Skyward is a Flutter airline-tycoon sim with:
- feature-first structure
- Cubit-owned app state
- Supabase/Postgres as the authoritative backend
- simulation-driven reloads through `SimulationReactiveMixin`
- a shared cockpit-style design system built from `AppTheme`, `AppTypography`, `AppSpacing`, `AppStrings`, and shared presentation widgets

## Composition root

`DashboardScreen` creates the active runtime graph:
- `NavigationCubit`
- `SimulationCubit`
- `FleetCubit`
- `RoutesCubit`
- `FinanceCubit`
- `LeaderboardCubit`
- `LazyTabCubit`
- `BlueprintPlannerFormCubit`
- `SettingsCubit` is provided in `main.dart` at app level
- `BankCubit`

`SimulationCubit` is the central backend-reconciliation source.
Other feature cubits subscribe through `SimulationReactiveMixin`.
`FinanceCubit` and `LeaderboardCubit` are initialized lazily when their
workspaces are first opened.
Realtime subscriptions are a freshness layer only. The current runtime also
forces explicit resync/reload passes after finance-heavy mutations so visible
clock, cash, ledger, and profile state do not wait on tab changes or staggered
Postgres Changes delivery.
`AchievementCubit` still exists in the repo, but it is not currently mounted
by the dashboard runtime graph.

## Gateway pattern

Every Cubit that communicates with Supabase does so through a dedicated
gateway. There are nine gateways in total:

| Gateway | Supabase surface |
|---------|-----------------|
| `AuthGateway` | `register-with-username` Edge Function |
| `SimulationGateway` | `process_simulation_delta`, `users`, `game_config` |
| `FleetGateway` | `purchase_aircraft`, `lease_aircraft`, `repair_aircraft`, `sell_aircraft`, `terminate_aircraft_lease`, `configure_aircraft_seats` |
| `RoutesGateway` | `create_route`, `assign_aircraft_to_route`, `update_route_frequency_and_price`, `delete_route` |
| `FinanceGateway` | `get_finance_snapshot` |
| `LeaderboardGateway` | `get_global_leaderboard`, `get_competitor_insights` |
| `SettingsGateway` | `reset_user_airline`, `save_airline_settings`, `delete-account` |
| `BankGateway` | `take_loan`, `get_credit_report`, `repay_loan`, `refinance_loan`, `finance_aircraft` |
| `AchievementGateway` | achievement tracking reads |

Each gateway defines an abstract interface and a `Supabase*Gateway`
implementation. This makes Cubits testable with mock gateways.

## Backend truth

Flutter does not calculate authoritative economy outcomes.
The client displays backend results and sends user commands.

Important backend responsibilities:
- auth/session validation
- shared season-clock ticking
- actor simulation reconciliation
- aircraft purchase/lease/repair
- route creation and updates
- leaderboard payloads and competitor insights
- ledger/history reads

See:
- [supabase-contracts.md](supabase-contracts.md)
- [database.md](database.md)
- [../../README.md](../../README.md)

Security migration note:
- Security Phase 1 adds `users.auth_user_id` plus shared username/email helper
  functions as the foundation for the planned Supabase Auth cutover.
- Security Phase 2 adds a server-side username registration surface that
  creates auto-confirmed synthetic-email auth identities.
- Live DB verification confirms `handle_new_auth_user()` is attached to
  `auth.users`, but that attachment is not declared by the public migrations
  alone.
- Security Phase 3 switches the Flutter auth flow to Supabase Auth sessions,
  while preserving the username-only UX through synthetic emails.
- Security Phase 4 starts moving client-facing gameplay RPCs onto auth-bound
  wrappers that resolve the player row from `auth.uid()` instead of trusting
  `p_user_id` from the client.
- Security Phase 5 enables RLS on the app-facing read surface, converts the
  auth-bound wrappers to security-definer execution, and retires client access
  to the legacy custom-session RPCs.
- Security Phase 6 removes the legacy custom-session database functions and the
  `sessions` table entirely.

## Current time authority

Production game time is backend-owned:
- `season_clock.current_game_time` is the shared season time
- `users.game_current_time` is the human-player progress cursor
- bot progression is backend-owned and advanced by the world-tick path
- `process_world_tick()` advances the season and actors
- `process_simulation_delta()` is a Flutter compatibility reconciliation RPC
- production Flutter does not locally advance game time

## UI state of the repo

Recent work tightened:
- typography scale
- spacing rhythm
- table/card/dialog consistency
- shared copy centralization
- medium-width responsiveness on dense operational screens
- scheduled maintenance slot previews and backend wear recovery rules
- route blueprinting now uses an interactive tile-backed world map with live network overlays
- route assignment and schedule validation now enforce range and weekly flight
  physics at the backend boundary
- cabin seat configuration now affects effective passenger capacity in both
  player and bot simulation
- players can now dispose of idle aircraft through sale or lease termination
- a private owner/operator optimizer RPC now exists for SQL-side route planning
- dashboard/fleet/routes tab content now lazy-loads through `LazyTabCubit`
- debug builds now emit lightweight `[PERF]` logs for load/reload auditing
- notification panel widget for in-app game event alerts
- onboarding overlay for first-time player guidance
- help tooltip widget for contextual inline explanations
- Finance historical charting currently falls back to a single current
  net-worth point until a real historical finance-snapshot surface exists
- bank/credit native SQL audit now proves `take_loan`, `repay_loan`,
  `refinance_loan`, and `get_credit_report`
- actor-parity hardening now also shares bankruptcy side effects and repair
  side effects across player and bot mutation paths
- delete-account now has a live-proven end-to-end audit script
- aircraft, bank, settings-save, and airline-reset flows now force
- route and fleet mutation flows now also force
  authoritative follow-up reloads for the affected cubits instead of relying
  purely on realtime propagation
- chronology hardening now also proves that repayment, lease termination, loan
  origination, and aircraft financing ledger rows stay on the shared game
  clock instead of drifting to wall-clock or truncated midnight timestamps

Leaderboard sorting was intentionally removed.
Rankings now always default to net worth order.

## Docs and migrations

Project records now live in:
- `docs/`
- `migrations/`
- `docs/README.md`

Apply SQL migrations from `migrations/` in numeric order.
Treat docs in `docs/` as the current maintenance record.

## Quality baseline

Local verification target:
- `flutter analyze`
- `flutter test`

Live backend verification target:
- `get_world_tick_guardrail_report()`
- `get_database_size_report()`
- `get_table_size_report()`

Do not treat handoff docs as the source of current live numbers. Re-run the SQL
audits when you need real operational state.

## Maintenance priorities

1. Fix real UI/runtime issues as they appear during live use.
2. Keep docs aligned with the code, not with old plans.
3. Preserve Cubit-only app state boundaries.
4. Avoid reintroducing blocking loaders where silent refresh is enough.
5. Keep lazy workspace initialization and reload throttling aligned with docs.
6. Keep reset, simulation, repair, and finance-refresh behavior aligned across
   Flutter and SQL.
7. Do not treat bot cooldowns, distress gating, or autonomous timing as parity
   bugs by default; those are intentional policy differences unless the shared
   mutation side effects drift again.
8. Keep Phase 9 isolated: deterministic daily simulation changes economy
   semantics and should not be bundled with UI or docs work.
9. Keep validating the ledger-retention audit RPCs before any live maintenance
   runs.
10. Next backend policy step is Phase 16 foundation: player activity tracking,
   simulation status, and inactive-player audit/reporting.
11. Finance now separates current balance-sheet state from rolling 30-day ledger
    analytics. The backend contract for both human players and bots is
    `get_finance_snapshot()`.
12. `get_finance_snapshot.active_route_count` now reflects only active route
    rows; if a future change broadens it to total route history, treat that as
    a contract change and update docs/tests in the same pass.
13. Security hardening is now an active backend track. Do not add new client
    RPCs that trust caller-supplied `p_user_id`; future work will bind gameplay
    access to `auth.uid()` and RLS.
14. The event system (`game_events`) generates time-bounded effects during world
    ticks. Future event types or UI surfacing should go through the existing
    `generate_game_events` / `deactivate_expired_events` contract.
15. Aviation depth features (turnaround, crew costs, seasonal demand,
    A/C-check milestones, cargo revenue, non-linear degradation) are live in
    the simulation engine. Any simulation formula changes must be reflected in
    both the player and bot processing functions.
