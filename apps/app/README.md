# skyward app (Flutter)

Flutter client (Web & Desktop). State is Cubit-owned; all authoritative economy
logic lives in the Go backend (`apps/api`) — the client displays and commands, never simulates.

- Run (from repo root): `make dev-app` (talks to `http://localhost:8090` in dev; see `lib/core/config/app_env.dart`).
- Checks: `make analyze`, `make test` (test layers 1–4 under `test/`).
- Docs: structure & patterns in [`../../docs/architecture/frontend.md`](../../docs/architecture/frontend.md),
  UI rules in [`../../docs/product/design-system.md`](../../docs/product/design-system.md),
  contribution & security notes in [`CONTRIBUTING.md`](CONTRIBUTING.md) / [`SECURITY.md`](SECURITY.md).
