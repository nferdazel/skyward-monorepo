# Skyward Monorepo Agent Guide

This file is universal for all models, coding agents, reviewers, or assistants working in this repository.

## Primary Rule

Treat the repo as a live product, not a scratchpad.
Prefer factual verification from code, tests, migrations, and linked runtime state over memory.

## Repository Layout

- `apps/app/`: Flutter frontend application (Web & Desktop).
- `apps/api/`: Go authoritative backend API (REST, WebSockets, simulation engine, world tick worker).
- `docs/`: System documentation, architecture diagrams, database schema, API contracts.
- `deploy/`: Container manifests, Podman Quadlet units, Caddy reverse proxy snippets.
- `scripts/`: Operational audit scripts, deployment scripts, database seeders.

## Source of Truth

Read these first before making non-trivial changes:

1. `README.md`
2. `docs/README.md`
3. `docs/architecture/ai-handover.md`
4. `docs/architecture/api-contract.md`
5. `docs/architecture/database.md`
6. `docs/standards/maintainer-standard.md`

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
