# Skyward

![Tests](https://img.shields.io/badge/tests-230%20passed-brightgreen)
![Flutter](https://img.shields.io/badge/Flutter-3.44-blue)
![Dart](https://img.shields.io/badge/Dart-3.12-blue)
![Supabase](https://img.shields.io/badge/Supabase-Postgres-3ecf8e)
![License](https://img.shields.io/badge/license-MIT-yellow)

Skyward is a Flutter airline-tycoon simulation with a Supabase/Postgres backend.
The app handles UI, local session flow, and command dispatch. The backend owns
authoritative simulation, economy, world time, and operational validation.

## Current shape

- Flutter frontend with feature-first modules
- Cubit-only app state
- Supabase-backed auth, simulation, finance, routes, fleet, leaderboard, bank, and achievement
- backend-owned world clock through `season_clock`
- human and bot actors sharing the same authoritative simulation rules

## Core features

- fleet acquisition, repair, seat configuration, and disposal
- route planning, pricing, assignment, and schedule management
- finance snapshots plus rolling ledger analytics
- bank/loan system with credit scoring and aircraft financing
- achievements system with rank history tracking
- AI competitor leaderboard with Intel panel
- backend world-tick simulation and actor reconciliation
- notification panel with typed alerts (info, success, warning, error, event)
- first-run onboarding overlay guiding new players through fleet, routes, and assignment
- network error recovery with auto-retry and manual retry action
- owner/operator SQL tools for private admin use
- dark tactical operations console UI with 4px border-radius design system

## Architecture

- `DashboardScreen` is the runtime composition root
- `NavigationCubit` owns tab selection state (index-based, sealed state)
- `SimulationCubit` is the central reconciliation source
- `LazyTabCubit` owns workspace lazy-load state for dashboard, fleet, and routes
- `FleetCubit`, `RoutesCubit`, `FinanceCubit`, and `LeaderboardCubit` react
  through `SimulationReactiveMixin`, but finance and leaderboard are lazy-init
  surfaces
- each feature uses a **gateway pattern** for data access: an abstract
  `*Gateway` interface with a `Supabase*Gateway` implementation that wraps all
  Supabase calls, handles errors, and throws typed `*GatewayException`s
- production Flutter observes backend time; it does not locally advance
  authoritative game time
- debug builds expose lightweight `[PERF]` instrumentation for load/reload audits

Desktop shell layout:
- sidebar (44px icon-only with tooltip labels, section grouping divider)
- HUD bar (40px with pill indicators, pipe separators, notification bell)
- main content workspace via `IndexedStack` (6 tabs: overview, fleet, routes, finance, leaderboard, settings)

For the maintained backend/runtime record, use:
- [docs/README.md](docs/README.md)
- [docs/architecture/ai-handover.md](docs/architecture/ai-handover.md)
- [docs/architecture/supabase-contracts.md](docs/architecture/supabase-contracts.md)

## Local setup

### Prerequisites

- Flutter SDK
- a Supabase project, or placeholder credentials for dev-mode mock data

### Install

```bash
flutter pub get
```

### Configure Supabase

Create local env config:

```bash
cp .env.example .env
dart run build_runner build
```

Required variables:

- `SUPABASE_URL`
- `SUPABASE_KEY`

If placeholder values remain, the app falls back to dev mode with mock data.

### Database setup

Apply SQL migrations in numeric order from:

- `migrations/`

### Run

```bash
flutter run
```

### Verify

```bash
flutter analyze
flutter test
```

## Deployment

Production web deployment is prepared for Vercel.

Required GitHub secrets:

- `VERCEL_TOKEN`
- `VERCEL_ORG_ID`
- `VERCEL_PROJECT_ID`
- `SUPABASE_URL`
- `SUPABASE_KEY`

## Repo guide

- `lib/`: Flutter application code
- `docs/` and `migrations/`: maintained SQL and backend/runtime docs
- `test/`: unit, widget, integration, and database-oriented test layers

## License

[MIT License](LICENSE)
