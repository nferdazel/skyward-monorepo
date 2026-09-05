#!/bin/bash
set -euo pipefail
REPO="${1:-skyward-monorepo}"
LOG="/srv/qouver/apps/skyward/logs/deploy.log"
mkdir -p /srv/qouver/apps/skyward/logs
echo "[$(date '+%Y-%m-%d %H:%M:%S')] deploy trigger: $REPO" | tee -a "$LOG"

if [ "$REPO" = "skyward-monorepo" ] || [ "$REPO" = "skyward" ]; then
  MONO_DIR="/srv/qouver/apps/skyward/monorepo"
  IS_FIRST=0
  if [ -d "$MONO_DIR/.git" ]; then
    cd "$MONO_DIR"
    git remote set-url origin github-skyward-monorepo:nferdazel/skyward-monorepo.git 2>&1 | tee -a "$LOG" || true
    OLD_REV=$(git rev-parse HEAD 2>/dev/null || echo "")
    git fetch origin main && git reset --hard origin/main 2>&1 | tee -a "$LOG"
    NEW_REV=$(git rev-parse HEAD 2>/dev/null || echo "")
    if [ "$OLD_REV" != "$NEW_REV" ] && [ -n "$OLD_REV" ]; then
      CHANGED_FILES=$(git diff --name-only "$OLD_REV" "$NEW_REV" 2>/dev/null || echo "apps/api/
apps/app/")
    else
      CHANGED_FILES="apps/api/
apps/app/"
    fi
  else
    echo "cloning skyward-monorepo -> $MONO_DIR" | tee -a "$LOG"
    git clone github-skyward-monorepo:nferdazel/skyward-monorepo.git "$MONO_DIR" 2>&1 | tee -a "$LOG"
    CHANGED_FILES="apps/api/
apps/app/"
    IS_FIRST=1
  fi

  # Deploy API jika folder apps/api/ berubah atau first run
  if echo "$CHANGED_FILES" | grep -q "^apps/api/" || [ "$IS_FIRST" -eq 1 ]; then
    echo "==> [skyward-monorepo] deploying API (apps/api)" | tee -a "$LOG"
    if [ -f "$MONO_DIR/apps/api/Dockerfile" ]; then
      cd "$MONO_DIR/apps/api"
      # Inject versi git ke binary via ldflags (lihat apps/api/Dockerfile ARG VERSION/COMMIT/DATE)
      GIT_VERSION=$(git describe --tags --always 2>/dev/null || echo dev)
      GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo none)
      GIT_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      podman build \
        --build-arg VERSION="$GIT_VERSION" \
        --build-arg COMMIT="$GIT_COMMIT" \
        --build-arg DATE="$GIT_DATE" \
        -t localhost/skyward-api:local . 2>&1 | tail -20 | tee -a "$LOG"
      mkdir -p /srv/qouver/apps/skyward/bin
      CONTAINER_ID=$(podman create localhost/skyward-api:local)
      podman cp "$CONTAINER_ID:/usr/local/bin/skyward-api" /srv/qouver/apps/skyward/bin/skyward-api
      podman rm "$CONTAINER_ID" >/dev/null
    fi
  fi
  systemctl --user daemon-reload 2>&1 | tee -a "$LOG"
  systemctl --user restart skyward-api 2>&1 | tee -a "$LOG"
  sleep 2
  systemctl --user is-active skyward-api 2>&1 | tee -a "$LOG"

  # Deploy Web jika folder apps/app/ berubah atau first run
  if echo "$CHANGED_FILES" | grep -q "^apps/app/" || [ "$IS_FIRST" -eq 1 ]; then
    echo "==> [skyward-monorepo] deploying Flutter Web (apps/app)" | tee -a "$LOG"
    # Kredensial build diambil dari env VPS (mode 600) — JANGAN hardcode di script
    # karena repo ini publik. Lihat deploy/env/skyward-prod.env.example.
    WEB_ENV="/srv/qouver/apps/skyward/env/skyward-prod.env"
    SUPABASE_URL=$(grep -E '^SUPABASE_URL=' "$WEB_ENV" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    SUPABASE_KEY=$(grep -E '^SUPABASE_KEY=' "$WEB_ENV" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_KEY" ]; then
      echo "==> ERROR: SUPABASE_URL/SUPABASE_KEY tidak ditemukan di $WEB_ENV — build web dibatalkan." | tee -a "$LOG"
      exit 1
    fi
    cd "$MONO_DIR/apps/app"
    podman build \
      --no-cache \
      --build-arg SUPABASE_URL="$SUPABASE_URL" \
      --build-arg SUPABASE_KEY="$SUPABASE_KEY" \
      -t localhost/skyward-web:local -f Dockerfile.web . 2>&1 | tail -20 | tee -a "$LOG"
    mkdir -p /srv/qouver/apps/skyward/web
    rm -rf /srv/qouver/apps/skyward/web/*
    CONTAINER_ID=$(podman create localhost/skyward-web:local)
    podman cp "$CONTAINER_ID:/var/www/html/." /srv/qouver/apps/skyward/web/
    podman rm "$CONTAINER_ID" >/dev/null
    restorecon -RF /srv/qouver/apps/skyward/web/ 2>&1 | tee -a "$LOG" || true
    # Catatan: Caddy file_server membaca direktori per-request — file baru langsung
    # ke-serve tanpa reload. Perubahan /etc/caddy/Caddyfile = manual via sudo
    # (caddy validate && systemctl reload caddy), bukan bagian deploy ini.
    echo "==> [skyward-monorepo] Flutter Web deploy complete" | tee -a "$LOG"
  fi
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] done $REPO" | tee -a "$LOG"
