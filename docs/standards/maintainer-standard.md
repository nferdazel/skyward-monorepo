# Skyward Maintainer Standard

Status: current | Last verified against code: 2026-09-11

This document is the repo-local operating contract for anyone changing Skyward.
When it conflicts with implementation convenience, this document wins.

## 1. Backend Truth

- `apps/api` (Go REST + WebSocket) is the authoritative backend for
  simulation, finance, credit, fleet, routes, bank, and world state.
- The Flutter client (`apps/app`) is display-only. It renders backend results
  and never implements authoritative economy or simulation logic locally.
- Postgres is the economic authority underneath the Go process, but app
  clients do not talk to it directly and the Supabase RPC / Edge Function era
  is over.
- Finance is bank-centric:
  - `bank_accounts.balance` is canonical cash.
  - `bank_transactions` is canonical money movement.
  - `users.net_worth` is reconciled state, not the authoritative cash store.
- Client ↔ backend transport: HTTP + WS. Dev listens on `127.0.0.1:8090`;
  prod is `https://api.qouver.com/skyward` (health `GET /healthz`).
- Realtime (`GET /ws`) is a freshness layer, not a consistency guarantee.
  Mutation success paths must trigger an explicit resync.

## 2. Source-of-Truth Doc Map

`docs/README.md` is the index. Start from it.

- Architecture: `docs/architecture/`
  - `overview.md` — system/component overview
  - `backend.md` — Go API, worker, auth, engine
  - `frontend.md` — Flutter app, cubits, gateways, realtime
  - `database.md` — live schema and migration-derived behavior
- Product: `docs/product/`
  - `design-system.md` — UI tokens and component rules
  - `roadmap.md` — forward-looking work *(not yet created)*
- Operations: `docs/operations/runbook.md` — sole ops surface.
- Standards: `docs/standards/maintainer-standard.md` — this file.
- `docs/reviews/` holds **dated historical artifacts** (e.g.
  `aviation-realism-review-2026-09.md`). They record what was true at review
  time. They are not current contracts and must not be cited as such.

Where a target doc does not exist yet, treat the closest existing equivalent
as the source of truth rather than inventing content. Do not reference files
that are not in the repo. The old `.commandcode/taste/*` references and the
Supabase-contracts framing are retired; do not reintroduce them.

## 3. Architecture Rules

- App state is Cubit-owned. No `setState` / `ValueNotifier` / `ChangeNotifier`
  for feature state.
- `StatefulWidget` is allowed only for widget-local lifecycle concerns
  (`TextEditingController`, `FocusNode`, animation disposal, dialog-local
  input). It is not a state-management substitute.
- Cubit-to-cubit references are forbidden; communicate across features with
  callbacks, streams, and `BlocListener`.
- Feature reactivity after simulation sync uses `SimulationReactiveMixin`; do
  not rewrite reactivity ad hoc.
- Every backend-facing feature uses the gateway pattern: an abstract
  `*Gateway` in `lib/features/<feature>/data/`, a concrete implementation of
  it, and a typed exception boundary. Cubits depend on the abstraction.
- DRY and KISS are strictly enforced. Do not invent patterns the repo already
  has. No static mutable state. Magic numbers belong in `GameConstants`.

## 4. Testing Bar

Run the relevant checks before closing meaningful work:

- `make analyze` — `flutter analyze` in `apps/app`.
- `make test` — `go test ./...` in `apps/api` **and** `flutter test` in
  `apps/app`.
- Flutter tests are organized into layers under `apps/app/test/`:
  `layer1_unit`, `layer2_widget`, `layer3_integration`, `layer4_database`.
  Gateway tests mock the abstract `*Gateway`, not the transport client.
- Go tests live alongside engine code (`apps/api/internal/engine/*_test.go`)
  and other packages.

Engine changes require a **worked numeric example** in the change description
or test — inputs, formula, expected output. A prose claim is not proof.

Database data fixes require **before/after `SELECT` evidence**: paste the query
and the observed rows before and after the fix. Behavior fixes belong in a
migration or engine code, not in an unrepeatable manual `UPDATE`.

## 5. Migration Convention

- Migrations are sequential and named `NN_name.sql`, applied in order:
  `00_baseline.sql` first, then `01_…` through the current `15_…`.
- Never edit a migration that has been applied. Add a new file instead.
- Each migration should state its apply command in the header
  (`psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -1 -f <file>`).
- Schema or data changes that a fresh environment needs must be captured in a
  migration, not left as manual live-DB state.
- Document behavior from active code paths, not from historical migration
  numbering. The old "Migration 25–46" numbering is obsolete.

## 6. Commit Conventions

- Conventional commits, scoped by area:
  - `feat(app):`, `fix(app):`, `docs:`
  - `feat(api):`, `fix(api):`
  - `test:` for test-only changes
- Prefer micro commits. Keep each change focused and reviewable.
- Do not commit, push, or rewrite history without explicit owner approval.

## 7. Documentation Rules

- Stale docs are defects. If code behavior changes materially, update the
  matching docs in the same workstream.
- Do not leave contradictory guidance in-repo when the current code is known.
- Doc filenames are kebab-case.
- Every current doc starts with:
  `Status: current | Last verified against code: YYYY-MM-DD`
- Historical artifacts live in `docs/reviews/` and are dated; do not present
  them as current behavior.

## 8. Review Checklist

- Is the backend still the source of truth with the client display-only?
- Is app state still Cubit-owned, with no cubit-to-cubit references?
- Is `SimulationReactiveMixin` reused rather than rewritten?
- Is the changed feature still going through its gateway abstraction?
- Are migrations append-only and documented?
- Did `make analyze` and `make test` pass?
- Did the docs move with the code?
