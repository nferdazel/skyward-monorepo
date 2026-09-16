#!/usr/bin/env bash
# Back up the Skyward database (custom format), verify the archive, prune old
# ones, and optionally copy off-box.
#
# Usage (VPS, podman):
#   PG_DUMP='podman exec qouver-postgres pg_dump -U qouver -d skyward' \
#   PG_RESTORE='podman exec -i qouver-postgres pg_restore' \
#   BACKUP_DIR=/srv/qouver/apps/skyward/backups scripts/backup-db.sh
#
# Usage (local):
#   DATABASE_URL=postgres://... BACKUP_DIR=./backups scripts/backup-db.sh
#
# Env:
#   PG_DUMP        full pg_dump command (takes precedence; must write to stdout)
#   DATABASE_URL   used to build the default pg_dump command
#   PG_RESTORE     pg_restore command used to verify the archive (default: pg_restore)
#   BACKUP_DIR     destination directory (default: ./backups)
#   RETENTION_DAYS delete archives older than this many days (default: 14)
#   BACKUP_REMOTE  optional rsync target, e.g. user@host:/srv/backups/skyward
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-./backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

if [ -n "${PG_DUMP:-}" ]; then
  # shellcheck disable=SC2206
  DUMP=($PG_DUMP)
elif [ -n "${DATABASE_URL:-}" ]; then
  DUMP=(pg_dump "$DATABASE_URL")
else
  echo "ERROR: set PG_DUMP or DATABASE_URL." >&2
  exit 1
fi
# shellcheck disable=SC2206
RESTORE=(${PG_RESTORE:-pg_restore})

mkdir -p "$BACKUP_DIR"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="$BACKUP_DIR/skyward-$stamp.dump"

echo "==> dump ke $out"
# Jangan pakai `-f -`: di PG 18 itu menulis ke file bernama `-` di dalam
# container, bukan ke stdout. Biarkan pg_dump menulis ke stdout secara default.
"${DUMP[@]}" -Fc > "$out"

size="$(wc -c < "$out" | tr -d ' ')"
if [ "$size" -lt 10000 ]; then
  echo "ERROR: arsip hanya $size byte — dump hampir pasti gagal." >&2
  rm -f "$out"
  exit 1
fi

# Arsip yang tidak bisa dibaca sama saja dengan tidak punya backup.
echo "==> verifikasi arsip"
tables="$("${RESTORE[@]}" -l < "$out" | grep -c 'TABLE DATA' || true)"
if [ "$tables" -lt 1 ]; then
  echo "ERROR: arsip tidak terbaca atau tidak berisi data tabel." >&2
  rm -f "$out"
  exit 1
fi
echo "    ok: $tables entri TABLE DATA, $size byte"

if [ -n "${BACKUP_REMOTE:-}" ]; then
  echo "==> salin ke $BACKUP_REMOTE"
  rsync -a --partial "$out" "$BACKUP_REMOTE/"
fi

echo "==> prune arsip lebih tua dari $RETENTION_DAYS hari"
find "$BACKUP_DIR" -maxdepth 1 -name 'skyward-*.dump' -type f -mtime "+$RETENTION_DAYS" -print -delete

kept="$(find "$BACKUP_DIR" -maxdepth 1 -name 'skyward-*.dump' -type f | wc -l | tr -d ' ')"
echo "==> selesai: $kept arsip tersimpan di $BACKUP_DIR"
