# Skyward Monorepo Agent Guide

This file is universal for all models, coding agents, reviewers, or assistants working in this repository.

## Primary Rule

Treat the repo as a live product, not a scratchpad.
Prefer factual verification from code, tests, migrations, and linked runtime state over memory.

## Repository Layout

- `apps/app/`: Flutter frontend application (Web & Desktop).
- `apps/api/`: Go authoritative backend API (REST, WebSockets, simulation engine, world tick worker).
- `docs/`: Single home for all documentation (architecture, product, operations, standards, dated reviews). Index: `docs/README.md`.
- `migrations/`: Sequential DB migrations, referenced by filename (`00_baseline.sql` … `NN_name.sql`). Append-only.
- `deploy/`: Container manifests, Podman Quadlet units, Caddy reverse proxy snippets.
- `scripts/`: Deployment scripts. Database audit SQL lives in `docs/operations/runbook.md`, not here.

## Source of Truth

Read these first before making non-trivial changes:

1. `docs/README.md` (index + reading paths)
2. `docs/architecture/overview.md` (system shape)
3. `docs/architecture/backend.md` / `frontend.md` (where your change lands)
4. `docs/architecture/database.md` (schema + migration index)
5. `docs/standards/maintainer-standard.md` (quality bar)
6. `docs/product/roadmap.md` (living backlog — tick items in the implementing commit)

## Architecture Expectations

- Flutter app state is Cubit-owned (`apps/app`).
- `skyward-api` Go backend (`apps/api`) is authoritative for simulation, finance, credit, and world state.
- Client code must not implement authoritative economy logic locally.
- Finance is bank-centric:
  - `bank_accounts` is canonical cash.
  - `bank_transactions` is canonical money movement.

## Testing Expectations

Before closing meaningful work, run the relevant checks:

- `make analyze` (runs `flutter analyze` in `apps/app`)
- `make test` (runs `flutter test` in `apps/app` and `go test ./...` in `apps/api`)

## Git & Commit Conventions

- Use conventional commit messages (`feat(app):`, `feat(api):`, `fix(app):`, `fix(api):`, `docs:`).
- Keep changes minimal and focused.
