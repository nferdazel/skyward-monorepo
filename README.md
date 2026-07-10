# Skyward

![Tests](https://img.shields.io/badge/tests-244%20passed-brightgreen)
![Flutter](https://img.shields.io/badge/Flutter-3.44-blue)
![Dart](https://img.shields.io/badge/Dart-3.12-blue)
![Supabase](https://img.shields.io/badge/Supabase-Postgres-3ecf8e)
![License](https://img.shields.io/badge/license-MIT-yellow)

Skyward is a Flutter airline-tycoon simulation with a Supabase/Postgres backend.
The app handles UI, local session flow, and command dispatch. The backend owns
authoritative simulation, economy, world time, and operational validation.

Last verified against code, docs, and linked live audit state on `2026-07-10`.

## Current shape

- Flutter frontend with feature-first modules
- Cubit-only app state
- Supabase-backed auth, simulation, finance, routes, fleet, leaderboard, bank,
  and settings data surfaces
- backend-owned world clock through `season_clock`
- bank-centric cash model:
  - `bank_accounts` is canonical cash
  - `bank_transactions` is canonical money trail
- auth-bound gameplay RPC wrappers using `auth.uid()`
- live-proven account bootstrap and delete-account flows
- native SQL audit now proves core fleet, route, finance, settings, and
  trigger paths against the linked database
- human and bot actors sharing the same authoritative simulation rules where intended

## Core features

- fleet acquisition, repair, seat configuration, and disposal
- route planning, pricing, assignment, and schedule management
- current finance snapshot plus rolling operating analytics
- bank transaction history as the live financial activity surface
- bank/loan system with credit scoring and aircraft financing
- financial command center with credit rating sub-scores and debt summary
- IFRS-inspired profitability and net worth composition KPI cards on dashboard
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
  through `SimulationReactiveMixin`, but leaderboard is a lazy-init surface
- `FinanceCubit` is eagerly loaded so Overview KPI cards have data on first render
- realtime subscriptions are treated as a reflection layer, not a substitute
  for explicit post-mutation reloads
- aircraft actions, route actions, bank actions, settings save, and airline
  reset now force targeted resync/reload flows so HUD clock, cash, ledger
  history, and derived finance metrics stay aligned without tab hopping
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
- [docs/architecture/database.md](docs/architecture/database.md)
- [docs/operations/audit-queries.md](docs/operations/audit-queries.md)

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

### Live audit passes

Rollback-style native SQL audits:

```bash
SUPABASE_DISABLE_TELEMETRY=1 supabase db query --linked -f test/layer4_database/native_audit/supabase_audit_test.sql
SUPABASE_DISABLE_TELEMETRY=1 supabase db query --linked -f test/layer4_database/native_audit/finance_credit_regression_test.sql
```

Delete-account end-to-end audit:

```bash
test/layer4_database/native_audit/delete_account_e2e_audit.sh
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
- `.opencode/`: local agent context docs kept in sync during backend passes

## License

[MIT License](LICENSE)
