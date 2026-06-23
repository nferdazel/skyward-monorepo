# Skyward Architecture Baseline

Last verified against code on 2026-06-22.

## Application model

Skyward is a single-user airline-tycoon simulation with a Flutter frontend and a Supabase/Postgres backend.

The Flutter app is responsible for:
- Supabase Auth session flow and username-only auth UX
- dashboard shell and navigation
- rendering fleet, routes, finance, leaderboard, and settings surfaces
- dispatching user actions to Cubits

The backend is responsible for:
- authenticated identity ownership through `auth.uid()` and RLS-backed reads
- authoritative economy and simulation outcomes
- transactional validation
- leaderboard payloads
- competitor insights
- player operational-status transitions for failure and recovery pressure

The Phase 2 world-clock foundation is present through `season_clock`, Phase 3
adds scheduler-safe world-tick RPCs plus `world_tick_log`, Phase 4 wires a
pg_cron job to advance the season clock every minute, and Phase 5 synchronizes
player/bot actor rows to the shared season time. Actor fields
(`users.game_current_time` and `ai_competitors.game_current_time`) are retained
as progress cursors, but the shared season clock is now the source of elapsed
game time. New actors join at the active season time.

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
- `AchievementCubit`

Allowed local widget state is limited to widget lifecycle concerns such as:
- `TextEditingController`
- `FocusNode`
- dialog-local control composition

## Gateway pattern

Every Cubit that communicates with Supabase does so through a dedicated
gateway abstraction. There are nine gateways:

- `AuthGateway` / `SupabaseAuthGateway`
- `SimulationGateway` / `SupabaseSimulationGateway`
- `FleetGateway` / `SupabaseFleetGateway`
- `RoutesGateway` / `SupabaseRoutesGateway`
- `FinanceGateway` / `SupabaseFinanceGateway`
- `LeaderboardGateway` / `SupabaseLeaderboardGateway`
- `SettingsGateway` / `SupabaseSettingsGateway`
- `BankGateway` / `SupabaseBankGateway`
- `AchievementGateway` / `SupabaseAchievementGateway`

Each gateway defines:
- an abstract interface declaring the Supabase operations for that feature
- a concrete `Supabase*Gateway` implementation
- a dedicated `*GatewayException` type

This makes Cubits testable with mock gateways and keeps Supabase client
usage behind a single boundary per feature.

## Reactive flow

`SimulationCubit` calls the compatibility sync RPC and reads actor state. It is
not a time authority. Production game time is not locally advanced; it is
reflected from Supabase realtime updates and periodic backend reconciliation.

Feature cubits react to simulation sync completion through `SimulationReactiveMixin`.
They do not reference one another directly.
Dashboard, fleet, and routes also use `LazyTabCubit` to keep workspace/tab
initialization Cubit-owned instead of widget-owned.

The UI now also uses a hybrid Supabase Realtime reflection layer:
- `SimulationCubit` listens to `users`
- `FleetCubit` listens to `user_fleet`
- `RoutesCubit` listens to `user_routes` and `user_fleet`
- `FinanceCubit` listens to `financial_ledger`
- `LeaderboardCubit` listens to `ai_competitors`
- `AchievementCubit` listens to `achievements`
- `BankCubit` listens to `loans`

Realtime is used to reflect database writes into Cubit state faster.
It does not replace authoritative SQL simulation or periodic reconciliation.
`FinanceCubit` now uses simulation sync to refresh the current snapshot, while
full ledger reloads stay on finance-related realtime events.

## Auth and security model

- user-facing login remains `username + password`
- the backend maps usernames to synthetic auth emails
- Supabase Auth is the source of session truth
- client-facing gameplay RPCs resolve the actor row from `auth.uid()`
- app-facing direct reads are protected by RLS

## UI system

The shared UI system is anchored by:
- `AppTheme`
- `AppTypography`
- `AppSpacing`
- `AppStrings`

Shared widget primitives now cover:
- cards
- buttons
- badges
- dialogs
- empty states
- table shells and cells
- compact table actions
- control labels and dropdowns
- stat text / info strips / labeled values
- notification panel (`NotificationPanel`)
- onboarding overlay (`OnboardingOverlay`)
- help tooltip (`HelpTooltip`)

## Feature notes

### Fleet
- active fleet management
- acquisition market
- repairs
- seat configuration

### Routes
- route creation
- fare and schedule updates
- aircraft assignment
- route retirement
- maintenance-slot previewing for schedule pressure before commit
- interactive world-map network preview with live route and planned-route overlays

### Finance
- ledger reads
- category analytics
- executive summaries
- runway / burn-mix / coverage signals
- daily operating snapshots and pressure-oriented cash diagnostics
- financial snapshots for historical trend visualization

### Leaderboard
- net-worth-based global ranking
- competitor intelligence panels
- live backend status and doctrine summaries for bot competitors
- no client-side sorting controls

### Overview
- multi-cubit operational dashboard
- action queue for grounded fleet / route pressure / runway risk
- competitor watch and finance watch rollups
- player operational-status, distress streak, and recovery streak guidance
- debug builds expose lightweight `[PERF]` instrumentation around dashboard,
  fleet, routes, finance, leaderboard, and route-map reload paths

### AI competitors
- backend-controlled simulation and decision loop
- archetype-shaped fleet seeding and route deployment
- doctrine-driven route retuning, contribution-based distress cutbacks, and paid grounded-aircraft recovery
- premium cabin seat distributions per archetype (Regional 80/15/5, Aggressive 70/20/10, Premium 50/30/20)
- competitive response pricing when humans serve shared routes
- bot aircraft purchasing when cash reserves exceed 3x starting capital

### Event system
- `game_events` table stores time-bounded world events
- event types: `fuel_shock`, `demand_surge`, `weather`, `regulatory`
- `generate_game_events()` runs each world tick with 5% probability per event type
- `deactivate_expired_events()` marks past events inactive
- active events modify fuel prices, airport demand, and airport taxes in simulation
- catch-up subsidy gives trailing players (< 30% of leader net worth) a scaled government subsidy

### Aviation depth
- per-aircraft-type turnaround times on `aircraft_models` (0.5–2.0 hrs)
- fare-class demand elasticity: business/first class attract 30% fewer passengers than seat-ratio split
- crew cost model: $350/hr per flight hour
- seasonal demand modifiers: peak (Jun-Aug, Dec) 1.15×, off-season (Jan-Feb, Oct-Nov) 0.90×
- maintenance check milestones: A-check every 500 flights, C-check every 3000 flights
- cargo revenue: 10% of ticket revenue baseline, scaling with route distance up to 5000 km
- non-linear aircraft degradation: accelerating wear below 60% condition

### Bank
- loan origination and management
- credit scoring and credit history
- aircraft financing
- loan refinancing
- bot financial behavior integration

### Achievements
- achievement tracking and unlocking
- rank history progression
- achievement-gated milestones

### Settings
- airline profile / HQ / safety threshold
- UI scale
- airline reset flow
