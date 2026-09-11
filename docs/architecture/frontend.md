# Skyward Frontend Architecture

Status: current | Last verified against code: 2026-09-11

This page describes the Flutter client in `apps/app`. It is the UI/state
counterpart to the authoritative Go API documented in
[backend.md](backend.md). For the overall system shape see
[overview.md](overview.md); for persistence see [database.md](database.md).

> Supersedes the obsolete Supabase-era notes in `ai-handover.md` and
> `apps/app/README.md`. The client **no longer uses the Supabase SDK**. It
> talks to the Go API over HTTP ([`lib/core/api/api_client.dart`]) and a shared
> WebSocket ([`lib/core/realtime/`]).

## Client rule

The Flutter app **displays backend results and sends user commands**. It does
not compute authoritative economy outcomes — no local cash math, no local
flight-revenue calculation, no local credit scoring, and no local clock
advance. Server responses are the source of truth; local state is provisional
until the next refetch.

## Feature-first layout

`lib/` is split into three top-level areas:

- `features/` — 13 feature folders, each owning its own `data/`, `domain/`, and
  `presentation/` (some omit folders they do not need):
  `achievements`, `auth`, `bank`, `dashboard`, `events`, `finance`, `fleet`,
  `leaderboard`, `navigation`, `notification`, `routes`, `settings`,
  `simulation`.
- `core/` — cross-cutting infrastructure (API, realtime, sync, DI, config,
  theme tokens, constants, utils, widgets).
- `presentation/` — shared, app-wide UI that does not belong to one feature:
  `layout/` (`master_detail_shell.dart`, `slide_over_drawer.dart`), `theme/`
  (`app_typography.dart`, `app_spacing.dart`, `app_motion.dart`), and
  `widgets/` (30 reusable widgets such as `app_table_shell.dart`,
  `notification_panel.dart`, `onboarding_overlay.dart`, `skyward_sonner.dart`).

Inside a feature the usual shape is:

```
features/<name>/
  data/          *_gateway.dart (abstract) + go_*_gateway.dart (HTTP impl)
  domain/        models / value types
  presentation/  cubit/ (state + cubit) + views/ + widgets/
```

## Composition root

`main.dart` provides app-level cubits only:

- `AuthCubit` — created with `..autoLogin()`; drives `AppRouter` between
  `AuthScreen` (unauthenticated) and `DashboardScreen` (authenticated).
- `SettingsCubit` — provided above `MaterialApp`; its `uiScale` feeds
  `MediaQuery.textScaler`.

`DashboardScreen` (`lib/features/dashboard/presentation/views/dashboard_screen.dart`)
is the **runtime composition root**. Once authenticated, its
`_AuthenticatedDashboardShell` constructs and owns the per-user cubits:

| Cubit | Created in | Notes |
|---|---|---|
| `NavigationCubit` | shell `initState` | index-based tab selection (sealed state) |
| `SimulationCubit` | shell | central reconciliation source; `startLoop(...)` |
| `FleetCubit` | shell | eager load + `setupReactivity` |
| `RoutesCubit` | shell | eager load + `setupReactivity` |
| `FinanceCubit` | shell | eager load so Overview KPI cards render first |
| `BankCubit` | shell | eager load + `setupReactivity` |
| `LeaderboardCubit` | shell | lazy — loaded when tab is first opened |
| `LazyTabCubit` | shell | tracks which workspace tabs are materialized |
| `NotificationCubit` | shell | typed in-app alerts |
| `EventsCubit` | shell | game events; reactive to simulation |
| `AchievementsCubit` | shell | achievement tracking; reactive |

All are exposed through `MultiBlocProvider` and closed in `dispose`. The shell
keys `_AuthenticatedDashboardShell` by `authState.user.id`, so a different user
tears down and rebuilds the whole cubit graph.

Eager bootstrap order in `_bootstrapForUser`: `SimulationCubit.startLoop`,
then `FleetCubit`, `RoutesCubit`, `BankCubit`, `FinanceCubit` each load and call
`setupReactivity`, then `EventsCubit` / `AchievementsCubit` set up reactivity.
`LeaderboardCubit` is initialized lazily by `_ensureTabReady` when tab index 4
is first opened.

## Cubit state pattern

All feature state is Cubit-owned (`flutter_bloc`); there are no `Bloc`s. Each
feature defines a state hierarchy in `*_state.dart` (commonly sealed or
`Equatable`) and a cubit that exposes load/mutation methods. Cross-cutting
helpers:

- `SimulationReactiveMixin` (`core/mixins/`) — subscribe to `SimulationCubit`
  and run a callback when sync transitions `true → false` with no error
  (`subscribeToSimulation`, `subscribeToSimulationWithState`,
  `disposeReactivity`).
- `GoRealtimeMixin` (`core/realtime/`) — subscribe a cubit to WebSocket
  channels; events are notification-only and trigger REST refetches
  (`subscribeToRealtime`, `disposeRealtime`).
- `CubitActionRunner` (`core/utils/`) — shared action/error handling used by
  `FleetCubit`, `RoutesCubit`, and `BankCubit`.

`SimulationReactiveMixin` is the standard reload mechanism: a feature cubit
watches the simulation stream and reloads its own slice when a sync completes.
Realtime is explicitly a **freshness layer**, not a substitute for post-mutation
reloads.

## Gateway pattern

Every cubit that talks to the backend goes through a gateway. Each feature
declares an abstract `*Gateway` interface plus a `Go*Gateway` HTTP
implementation, and throws a typed `*GatewayException` (`AuthGatewayException`,
`BankGatewayException`, etc.). Cubits accept an optional gateway in their
constructor, which allows tests to inject mocks.

`GatewayFactory` (`lib/core/di/gateway_factory.dart`) lazily creates one shared
`ApiClient` and one shared `GoRealtimeClient`, and exposes a `create*Gateway()`
per feature:

| Gateway | Cubit | Backed by |
|---|---|---|
| `AuthGateway` | `AuthCubit` | Go API auth |
| `SimulationGateway` | `SimulationCubit` | Go API simulation |
| `FleetGateway` | `FleetCubit` | Go API fleet |
| `RoutesGateway` | `RoutesCubit` | Go API routes |
| `FinanceGateway` | `FinanceCubit` | Go API finance |
| `BankGateway` | `BankCubit` | Go API bank/loans |
| `LeaderboardGateway` | `LeaderboardCubit` | Go API leaderboard |
| `SettingsGateway` | `SettingsCubit` | Go API settings/reset |
| `EventsGateway` | `EventsCubit` | Go API events |
| `AchievementsGateway` | `AchievementsCubit` | Go API achievements |

`GatewayFactory` also exposes `@visibleForTesting` overrides for the shared
`ApiClient` and `GoRealtimeClient`.

### HTTP client

`ApiClient` (`core/api/api_client.dart`) wraps `package:http`:

- base URL from `AppEnv.apiBaseUrl`;
- injects `Authorization: Bearer <token>` from an `AuthTokenStore`
  (`SharedPrefsAuthTokenStore`);
- parses the Go error envelope `{"error":{"code","message"}}` into
  `ApiException` (`code` values include `unauthorized`, `validation`,
  `not_found`, `rate_limited`, `internal`, plus transport `network` /
  `timeout`).

### Realtime client

`GoRealtimeClient` (`core/realtime/go_realtime_client.dart`) opens
`GET /ws?token=<jwt>`, sends `subscribe` / `unsubscribe` / `ping`, and emits
`GoRealtimeEvent`s (`type`, `channel`, `event`, `at`). It reconnects with
exponential backoff (2s → max 30s), re-subscribes known channels, and pings
every 30s. A single connection is shared by all cubits via `GatewayFactory`.

## Sync and domain events

`core/sync/` provides an in-process event bus:

- `DomainEvent` and subclasses `FleetUpdatedEvent`, `RouteUpdatedEvent`,
  `BankTransactionEvent`, `SeasonClockTickEvent` (`domain_events.dart`).
- `SyncCoordinator` (`sync_coordinator.dart`) — a broadcast stream singleton
  with `publish`, `on<T>`, and `listen<T>(..., debounce:)`.

Publishers today are `FleetCubit`, `RoutesCubit`, and `SimulationCubit`.
Listeners use it to coordinate reloads without tight cross-cubit references.
This is separate from the WebSocket freshness layer.

## Configuration

`AppEnv` (`core/config/app_env.dart`, envied) reads build-time values:

- `SKYWARD_API_URL` → `apiBaseUrl`. Dev default `http://localhost:8090`; prod
  `https://api.qouver.com/skyward`.
- `SUPABASE_URL` / `SUPABASE_KEY` are still declared fields but are legacy from
  the Supabase era and are **not** used by the HTTP/WS path.

## Theme and design system

Dark-only tactical "aviation command" UI. Tokens are centralized:

- `SkywardColors` (`core/theme/skyward_colors.dart`) — raw color tokens
  (HUD blue accent `#5B9EE0`, ATC teal, semantic green/amber/red, tier colors,
  `opacity*` scale). Light mode was removed.
- `AppTheme` (`core/theme/app_theme.dart`) — maps tokens into a `ThemeData`
  (IBM Plex Sans via `google_fonts`, 4px border radius, semantic aliases such
  as `primary`, `background`, `surface*`, `border*`, `success`/`error`/`warning`).
- `AppTypography` (`presentation/theme/`) — text styles and letter-spacing
  tokens.
- `AppSpacing` (`presentation/theme/`) — 4px grid scale plus semantic spacing
  and border-radius tokens.
- `AppMotion` (`presentation/theme/`) — duration, curve, and press-scale tokens.
- `condition_colors.dart` and `app_formatters.dart` provide domain-specific
  presentation helpers.

## Tests

`apps/app/test/` is a four-layer suite (49 `_test.dart` files):

| Layer | Location | Files | Covers |
|---|---|---|---|
| 1 — unit | `test/layer1_unit/` | 37 | API client/gateways, cubits, domain models, business logic, theme, utils |
| 2 — widget | `test/layer2_widget/` | 9 | auth lifecycle, responsive overflow, reusable widgets, feature views |
| 3 — integration | `test/layer3_integration/` | 2 | auth flow, CRUD + realtime stream |
| 4 — database | `test/layer4_database/` | 1 test + SQL/sh | Go↔DB RPC/trigger integration, native SQL audits |

Run `flutter analyze` and `flutter test` from `apps/app` (or `make analyze` /
`make test` at the repo root).

## Removed

- The global command palette was removed in commit `e5f5ffa`; there is no
  command-palette widget in `lib/` or `test/` today. The finance ledger search
  is unaffected.
- The Supabase SDK, `Supabase*Gateway` implementations, Edge Functions, and the
  auth-bound SQL RPC path are no longer used by the client.
