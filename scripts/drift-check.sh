#!/usr/bin/env bash
# Drift check — apakah schema database hidup masih sama dengan yang dihasilkan
# migrasi? (refactor plan 0.3b)
#
# Dua perbandingan:
#   1. DB hidup  vs  scratch DB hasil apply semua migrasi  -> menangkap DDL yang
#      di-apply tangan ke DB hidup (sumber drift nyata di alur kerja kita).
#   2. scratch DB vs  snapshot yang di-commit              -> menangkap snapshot
#      yang basi setelah ada migrasi baru.
#
# Pemakaian (lokal, lewat tunnel ke VPS):
#   DATABASE_URL=postgres://qouver@127.0.0.1:15432/skyward scripts/drift-check.sh
#   DATABASE_URL=… scripts/drift-check.sh --update   # segarkan snapshot
#
# ADMIN_URL opsional; default = DATABASE_URL dengan nama database diganti
# `postgres` (koneksi maintenance untuk drop/create scratch DB).
# Scratch DB: $SCRATCH_DB (default skyward_drift) — dibuat ulang tiap jalan.
#
# Perbandingan mengabaikan owner dan ACL (`--no-owner --no-acl`): yang dinilai
# bentuk schema, bukan kepemilikan objek. Owner memang berbeda antar cluster
# (`postgres` vs `qouver`) tanpa berarti ada drift.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPSHOT="$DIR/docs/operations/schema-snapshot.sql"
SCRATCH_DB="${SCRATCH_DB:-skyward_drift}"
UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

: "${DATABASE_URL:?set DATABASE_URL (mis. postgres://qouver@127.0.0.1:15432/skyward)}"
ADMIN_URL="${ADMIN_URL:-${DATABASE_URL%/*}/postgres}"
SCRATCH_URL="${DATABASE_URL%/*}/$SCRATCH_DB"

command -v pg_dump >/dev/null || { echo "ERROR: pg_dump tidak ada di PATH" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Normalisasi: buang baris yang berubah antar cluster tanpa arti schema.
normalize() {
  sed -E \
    -e '/^\\/d' \
    -e '/^--/d' \
    -e '/^SET /d' \
    -e '/^SELECT pg_catalog\.set_config/d' \
    -e '/^[[:space:]]*$/d'
}

dump() { # dump <url> <tujuan>
  pg_dump -s --no-owner --no-acl --schema=public "$1" | normalize > "$2"
}

echo "==> menyiapkan scratch DB: $SCRATCH_DB"
psql "$ADMIN_URL" -q -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS $SCRATCH_DB WITH (FORCE);"
psql "$ADMIN_URL" -q -v ON_ERROR_STOP=1 -c "CREATE DATABASE $SCRATCH_DB;"

echo "==> menerapkan seluruh migrasi ke scratch DB"
DATABASE_URL="$SCRATCH_URL" bash "$DIR/scripts/migrate.sh"

echo "==> dump schema"
dump "$DATABASE_URL" "$TMP/live.sql"
dump "$SCRATCH_URL" "$TMP/scratch.sql"

status=0

echo
echo "==> 1/2 DB hidup vs hasil migrasi"
if diff -u "$TMP/live.sql" "$TMP/scratch.sql" > "$TMP/live-vs-scratch.diff"; then
  echo "    cocok — tidak ada drift"
else
  echo "    BEDA. DDL yang di-apply tangan ke DB hidup tidak ada padanannya di migrasi:"
  head -60 "$TMP/live-vs-scratch.diff"
  cp "$TMP/live-vs-scratch.diff" /tmp/drift-live-vs-scratch.diff
  echo "    diff lengkap: /tmp/drift-live-vs-scratch.diff"
  echo "    dump hidup: /tmp/drift-live.sql, dump migrasi: /tmp/drift-scratch.sql"
  cp "$TMP/live.sql" /tmp/drift-live.sql
  cp "$TMP/scratch.sql" /tmp/drift-scratch.sql
  status=1
fi

if [ "$UPDATE" -eq 1 ]; then
  mkdir -p "$(dirname "$SNAPSHOT")"
  cp "$TMP/scratch.sql" "$SNAPSHOT"
  echo
  echo "==> snapshot disegarkan: ${SNAPSHOT#"$DIR"/}"
  exit "$status"
fi

echo
echo "==> 2/2 hasil migrasi vs snapshot"
if [ ! -f "$SNAPSHOT" ]; then
  echo "    snapshot belum ada — jalankan dengan --update untuk membuatnya"
  exit 1
fi
if diff -u "$SNAPSHOT" "$TMP/scratch.sql" > "$TMP/snapshot.diff"; then
  echo "    cocok — snapshot masih akurat"
else
  echo "    BEDA. Snapshot basi (ada migrasi baru yang belum tercermin):"
  head -60 "$TMP/snapshot.diff"
  cp "$TMP/snapshot.diff" /tmp/drift-snapshot.diff
  echo "    diff lengkap: /tmp/drift-snapshot.diff"
  echo "    jalankan ulang dengan --update setelah yakin bedanya memang dari migrasi."
  status=1
fi

exit "$status"
