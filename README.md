# Skyward Monorepo

Skyward is an airline-tycoon simulation composed of:
- **`apps/app`**: Flutter frontend client (Web & Desktop).
- **`apps/api`**: Authoritative Go backend API (REST + WebSockets, simulation engine, world-tick worker).
- **PostgreSQL**: single database, written to exclusively by the Go backend.

All documentation lives in [`docs/`](docs/README.md) — start with
[`docs/architecture/overview.md`](docs/architecture/overview.md).

## Repository Structure

```text
skyward-monorepo/
├── apps/
│   ├── app/                # Flutter frontend client
│   └── api/                # Go HTTP API & simulation worker
├── docs/                   # Architecture, product, operations, standards, reviews
├── migrations/             # Sequential DB migrations (00_baseline … NN_name.sql)
├── deploy/                 # Docker Compose, VPS Podman Quadlet / Caddy / systemd manifests
├── scripts/                # Deployment tools
├── AGENTS.md               # Agent/repo working rules
└── Makefile                # Root task runner (make dev, make test, make analyze)
```

## Quick Start

### Prerequisites
- Go 1.22+
- Flutter SDK 3.24+
- PostgreSQL 18

### Development Setup
1. Copy `.env.example` to `.env`:
   ```bash
   cp .env.example .env
   ```
2. Run backend API:
   ```bash
   make dev-api
   ```
3. Run Flutter app:
   ```bash
   make dev-app
   ```

## License
MIT
