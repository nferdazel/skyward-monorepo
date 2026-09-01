# Skyward Monorepo

Skyward is an airline-tycoon simulation application composed of:
- **`apps/app`**: Flutter frontend client (Web & Desktop).
- **`apps/api`**: Authoritative Go backend API (REST + WebSockets, simulation engine, world-tick worker).

## Repository Structure

```text
skyward-monorepo/
├── apps/
│   ├── app/                # Flutter frontend client
│   └── api/                # Go HTTP API & simulation worker
├── docs/                   # Unified architecture, database, API contract & handover docs
├── deploy/                 # Docker Compose, VPS Podman Quadlet / Caddy / systemd manifests
├── scripts/                # Database audit scripts & deployment tools
├── Makefile                # Root task runner (make dev, make test, make analyze)
└── README.md
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
