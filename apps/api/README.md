# skyward-api

Authoritative Go backend: REST API, WebSocket push, simulation engine, and the
in-process world-tick worker. Single binary (`cmd/server`), PostgreSQL via `pgx`.

- Run (from repo root): `make dev-api` — requires `.env` with `DATABASE_URL` (see `.env.example`).
- Tests: `go test ./...` (domain logic in `internal/engine` is covered; HTTP layer is not yet).
- Docs: architecture & route inventory in [`../../docs/architecture/backend.md`](../../docs/architecture/backend.md),
  system shape in [`overview.md`](../../docs/architecture/overview.md), ops in
  [`../../docs/operations/runbook.md`](../../docs/operations/runbook.md).
