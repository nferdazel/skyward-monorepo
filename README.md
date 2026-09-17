# Skyward

An airline-tycoon simulation: you found an airline, buy or lease aircraft, open
routes, set fares, and keep the balance sheet alive while a shared world runs
underneath you.

The interesting part is architectural. **The client computes nothing about the
economy.** Demand, fares, wear, credit, and cash flow are all decided by the Go
backend, which is authoritative, and the Flutter client renders what it is told.
If the server and the client ever disagree, the server is right by definition.
That rule is what most of this repo's design follows from.

## What it is

- **`apps/app`**, the Flutter client for Web and Desktop. Cubit-owned state.
- **`apps/api`**, the Go API and simulation engine. REST + WebSockets, plus
  the world-tick worker (the same binary).
- **PostgreSQL**, one database, written to exclusively by the Go backend.

The world ticks once a minute on game time. During a tick the server advances
every airline: it flies the routes, burns fuel, pays crew, wears down airframes,
services loans, runs the AI competitors, and can bankrupt you.

## What you can do

| | |
|---|---|
| **Found an airline** | Register, pick an HQ airport, and start with working capital |
| **Build a fleet** | Buy outright or lease; assign each airframe to a route |
| **Open routes** | Any airport pair; set the ticket price and weekly frequency |
| **Read the numbers** | Per-route profit projection before you commit, from the same engine that runs the tick |
| **Stay solvent** | Loans, aircraft financing, credit tiers, and a bankruptcy clock |
| **Watch the world** | Market events, competitor airlines on a leaderboard, achievements |

Aircraft wear out as they fly. Repair them, or eat the maintenance. The route
economics are genuinely unforgiving. Long-haul flying on a narrow-body is
usually a bad idea, and the dashboard will tell you so rather than hide it.

## Repository layout

```text
skyward-monorepo/
├── apps/
│   ├── app/                Flutter client (Web & Desktop)
│   └── api/                Go API, simulation engine, world-tick worker
├── docs/                   Architecture, product, operations, standards
├── migrations/             Sequential DB migrations (00_baseline … 24_…)
├── deploy/                 Deploy script, Caddy config, prod env template
├── scripts/                Migration, backup, drift-check, deploy tooling
├── AGENTS.md               Working rules for agents and contributors
└── Makefile                Root task runner
```

## Getting started

**Prerequisites:** Go 1.26.5+ (`apps/api/go.mod`), Flutter SDK with Dart 3.12+
(`apps/app/pubspec.yaml`), PostgreSQL 18.

```bash
cp .env.example .env     # then fill in DATABASE_URL and SKYWARD_JWT_SECRET
make migrate             # apply migrations to a fresh database
make dev-api             # Go API on :8090
make dev-app             # Flutter client
```

`make migrate` is enough to produce a working environment on its own: it seeds
the reference data (airports, aircraft models), the game config, and the active
season. No manual SQL.

```bash
make test      # Go tests + Flutter tests
make analyze   # flutter analyze
```

## Development notes

A few things that are easy to get wrong, and that the codebase actively enforces:

- **Never put economy logic in the client.** Route projections come from
  `GET /routes/assess`; the client has no demand model, and adding one back
  would immediately drift from the tick.
- **Money comparisons use `apps/api/internal/engine/money.go`.** Costs computed
  from division land slightly above their cent value in `float64`, so a raw `<`
  rejects players whose funds are exactly enough. Amounts round to the cent once,
  at the ledger boundary.
- **The tick reads one `TickSnapshot`**, never per-key config lookups, so a
  single tick cannot see two different values for the same config key.
- **`migrations/00_baseline.sql` is a Supabase-era dump** and most of the SQL
  functions inside it are dead. Its header says which 13 still run and why the
  rest are kept. Do not treat `process_world_tick` or `take_loan` in there as
  current behaviour. The Go engine is authoritative.

## Documentation

[`docs/README.md`](docs/README.md) is the index. Good entry points:

- [`docs/architecture/overview.md`](docs/architecture/overview.md): system shape, who owns the truth
- [`docs/architecture/backend.md`](docs/architecture/backend.md): engine layout and HTTP surface
- [`docs/architecture/frontend.md`](docs/architecture/frontend.md): Flutter structure and test layers
- [`docs/architecture/database.md`](docs/architecture/database.md): schema and migration index
- [`docs/standards/decisions.md`](docs/standards/decisions.md): owner decisions and open work
- [`docs/operations/runbook.md`](docs/operations/runbook.md): operations, troubleshooting, audit SQL

## License

MIT. See [`LICENSE`](LICENSE).
