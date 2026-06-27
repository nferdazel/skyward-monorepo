# Skyward Architecture Baseline

Last verified against code on 2026-06-27.

## Application model

Skyward is a Flutter airline-management sim with a Supabase/Postgres backend.

The Flutter app is responsible for:
- Supabase Auth session flow and username-only login UX
- dashboard shell and navigation
- Cubit-owned state orchestration
- rendering fleet, routes, finance, leaderboard, bank, achievements, and settings

The backend is responsible for:
- authoritative economy, credit, and simulation outcomes
- bank balances and financial mutation history
- transactional validation
- world-time progression
- player and bot processing
- leaderboard and competitor insight payloads

## State management

App state is Cubit-owned.

Current runtime cubits:
- `AuthCubit`
- `NavigationCubit`
- `SimulationCubit`
- `FleetCubit`
- `RoutesCubit`
- `FinanceCubit`
- `LeaderboardCubit`
- `LazyTabCubit`
- `BlueprintPlannerFormCubit`
- `SettingsCubit`
- `BankCubit`

Repo-present but not mounted in the active dashboard runtime:
- `AchievementCubit`

Allowed widget-local state remains limited to lifecycle concerns such as
controllers, focus nodes, and dialog-local composition.

## Gateway pattern

Every Supabase-facing feature uses a dedicated gateway abstraction:
- `AuthGateway`
- `SimulationGateway`
- `FleetGateway`
- `RoutesGateway`
- `FinanceGateway`
- `LeaderboardGateway`
- `SettingsGateway`
- `BankGateway`
- `AchievementGateway`

Each gateway defines an abstract interface, a concrete `Supabase*Gateway`, and
a typed exception boundary.

## Backend-owned time and simulation

Production game time is backend-owned:
- `season_clock.current_game_time` is shared season time
- `users.game_current_time` is the player cursor
- bot progress is coordinated by the backend world-tick path
- `process_world_tick()` advances the season and actor state
- `process_simulation_delta()` is a compatibility reconciliation RPC for the current player

Flutter does not locally advance authoritative game time.

## Realtime reflection

Realtime is a reflection layer, not a source of truth.

Current live subscriptions:
- `SimulationCubit` listens to `users`, `bank_transactions`, `fleet_aircraft`, and `route_assignments`
- `FleetCubit` listens to `fleet_aircraft`
- `RoutesCubit` listens to `route_assignments`
- `FinanceCubit` listens to `bank_transactions`
- `BankCubit` listens to `loans`, `bank_accounts`, and `bank_transactions`
- `AchievementCubit` listens to `achievements` when mounted, but the current
  dashboard runtime does not instantiate it

`LeaderboardCubit` refreshes through RPC reads rather than owning a direct
Postgres Changes subscription.

Operational rule:
- mutation success paths that materially affect cash, ledger chronology, or
  profile-owned simulation inputs should not rely on Postgres Changes alone
- current Flutter runtime explicitly resyncs after aircraft acquisition /
  disposal / repair flows, route mutation flows, bank loan / refinance /
  financing flows, settings save, and airline reset
- this keeps `SimulationCubit`, `BankCubit`, `FinanceCubit`, and profile-owned
  consumers aligned even when realtime delivery is delayed or staggered

## Canonical financial model

Skyward is now bank-centric:
- `bank_accounts.balance` is canonical cash
- `bank_transactions` is canonical financial history
- `users.net_worth` is reconciled state, not the authoritative cash store
- fleet and loan mutations reconcile net worth through database logic

## Auth and security model

- user-facing login remains `username + password`
- usernames map to synthetic auth emails
- Supabase Auth is the source of session truth
- gameplay RPC wrappers resolve the player row from `auth.uid()`
- app-facing reads are protected by RLS
- live DB verification confirms `handle_new_auth_user()` is attached to `auth.users`
- the repo's public migrations still do not declare that auth-side trigger attachment

## Primary user-facing surfaces

Fleet:
- acquisition
- repairs
- sale / lease termination
- seat configuration

Routes:
- route creation
- aircraft assignment
- fare and frequency updates
- route retirement
- world-map-backed planning

Finance:
- current snapshot from `get_finance_snapshot()`
- bank transaction history
- rolling operating metrics

Bank:
- loan origination
- refinancing
- repayment
- aircraft financing
- credit reporting

Settings:
- airline profile and HQ
- safety / auto-grounding configuration
- reset flow
- account deletion flow through Edge Function

## Current documentation rule

Treat the docs in `docs/` as the active maintenance record.
Do not trust older migration-era naming such as `user_fleet`, `user_routes`,
or `financial_ledger` unless the current code still uses them.
