#!/usr/bin/env bash
# NOTE (2026-09-03): DEPRECATED untuk update — skyward-api berjalan sebagai
# BINARY NATIVE (systemd user unit, ExecStart=/srv/qouver/apps/skyward/bin/skyward-api),
# bukan container. Deploy otomatis via webhook -> deploy/deploy-vps.sh (disalin ke
# server). deploy/skyward-api.container masih aspirational (belum dipakai).
#
# Deploy skyward-api ke VPS — pull image ghcr.io + restart systemd user unit.
#
# Prasyarat sekali:
#   - DNS api.qouver.com → A → <vps-ip> (sudah ada)
#   - Caddy site (deploy/Caddyfile.api.qouver.com) sudah di-apply (butuh sudo)
#   - Env file ada di VPS: /srv/qouver/apps/skyward/env/skyward-prod.env (chmod 600)
#   - DB skyward sudah dibuat (CREATE DATABASE + migration). Instansi dev dihapus (2026-09-05).
#
# Usage:
#   ./scripts/deploy.sh setup       # sekali: install quadlet unit + enable service
#   ./scripts/deploy.sh             # update: restart service prod
set -euo pipefail

VPS="${VPS:-sachiel@43.133.148.191}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")/deploy"

MODE="${1:-update}"
UNIT="skyward-api"
INSTANCE="prod"

echo "==> instance: $INSTANCE (unit: $UNIT)"

if [ "$MODE" = "setup" ]; then
  echo "==> [setup] install quadlet unit + enable service"
  ssh "$VPS" "mkdir -p ~/.config/containers/systemd"
  scp -q "$DEPLOY_DIR/$UNIT.container" "$VPS:~/.config/containers/systemd/"
  ssh "$VPS" "loginctl enable-linger \$(whoami) 2>/dev/null || true; systemctl --user daemon-reload; systemctl --user enable --now $UNIT"
  echo "==> setup selesai. Env file harus ada di VPS:"
  echo "    /srv/qouver/apps/skyward/env/skyward-${INSTANCE}.env (chmod 600)"
else
  echo "==> [update] restart (Pull=always mengambil image terbaru)"
  ssh "$VPS" "systemctl --user restart $UNIT; sleep 2; systemctl --user --no-pager status $UNIT | head -8"
fi