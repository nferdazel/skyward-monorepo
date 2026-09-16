#!/usr/bin/env bash
# Apply pending migrations in order and record them in `schema_migrations`.
#
# Usage (local):
#   DATABASE_URL=postgres://user:pass@host:5432/db scripts/migrate.sh
# Usage (VPS, podman):
#   PSQL='podman exec -i qouver-postgres psql -U qouver -d skyward' scripts/migrate.sh
#
# Safety: if the target database has a non-empty `public` schema but no
# `schema_migrations` table, the script refuses to run — otherwise it would
# re-apply already-applied migrations. Apply `migrations/19_schema_migrations.sql`
# manually first (see docs/operations/runbook.md §5).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIG_DIR="$DIR/migrations"

if [ -n "${PSQL:-}" ]; then
  # shellcheck disable=SC2206
  PSQL_CMD=($PSQL)
else
  : "${DATABASE_URL:?set DATABASE_URL, or PSQL for a custom psql invocation}"
  PSQL_CMD=(psql "$DATABASE_URL")
fi

q()  { "${PSQL_CMD[@]}" -q -tA -v ON_ERROR_STOP=1 -c "$1"; }
run(){ "${PSQL_CMD[@]}" -v ON_ERROR_STOP=1 "$@"; }

sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

ledger_exists="$(q "SELECT to_regclass('public.schema_migrations') IS NOT NULL")"
if [ "$ledger_exists" != "t" ]; then
  table_count="$(q "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")"
  if [ "$table_count" != "0" ]; then
    echo "ERROR: database ini sudah punya $table_count tabel di schema public tapi belum" >&2
    echo "       punya tabel schema_migrations. Menjalankan migrate di sini akan" >&2
    echo "       menerapkan ulang migrasi lama." >&2
    echo "       Terapkan migrations/19_schema_migrations.sql secara manual dulu." >&2
    exit 1
  fi
  echo "==> membuat tabel schema_migrations (database kosong)"
  run -q -c "CREATE TABLE IF NOT EXISTS schema_migrations (
      filename text PRIMARY KEY, checksum text,
      applied_at timestamptz NOT NULL DEFAULT now());"
fi

applied=0
for file in "$MIG_DIR"/*.sql; do
  name="$(basename "$file")"
  esc="${name//\'/\'\'}"
  sum="$(sha "$file")"
  recorded="$(q "SELECT 1 FROM schema_migrations WHERE filename='$esc'")"
  [ "$recorded" = "1" ] && continue
  pending_checksum="$(q "SELECT COALESCE(checksum,'') FROM schema_migrations WHERE filename='$esc'")"

  echo "==> applying $name"
  # Lewat STDIN, bukan `-f`: dengan PSQL='podman exec -i ...' psql berjalan di
  # dalam container dan tidak bisa membaca path di host.
  # Migrasi sudah punya BEGIN/COMMIT sendiri; jangan bungkus lagi dengan -1.
  "${PSQL_CMD[@]}" -q -v ON_ERROR_STOP=1 < "$file"
  run -q -c "INSERT INTO schema_migrations (filename, checksum) VALUES ('$esc', '$sum')
             ON CONFLICT (filename) DO UPDATE SET checksum = EXCLUDED.checksum"
  applied=$((applied + 1))
  if [ -z "$pending_checksum" ]; then :; fi
done

# Verify that migrations recorded with a checksum still match on disk.
mismatch=0
while IFS='|' read -r name sum; do
  [ -z "$name" ] && continue
  [ -z "$sum" ] && continue
  if [ -f "$MIG_DIR/$name" ]; then
    if [ "$(sha "$MIG_DIR/$name")" != "$sum" ]; then
      echo "ERROR: $name sudah diterapkan tapi isinya berubah (checksum beda)." >&2
      mismatch=1
    fi
  else
    echo "ERROR: $name tercatat di ledger tapi filenya hilang." >&2
    mismatch=1
  fi
done < <(q "SELECT filename||'|'||checksum FROM schema_migrations WHERE checksum IS NOT NULL")

if [ "$mismatch" -eq 1 ]; then
  echo "       Migrasi bersifat append-only: jangan edit/hapus yang sudah diterapkan." >&2
  exit 1
fi

if [ "$applied" -eq 0 ]; then
  echo "==> tidak ada migrasi pending"
else
  echo "==> selesai: $applied migrasi diterapkan"
fi
