#!/usr/bin/env bash
# Regenerate migrations/20_reference_data_seed.sql from a live database.
#
# `00_baseline.sql` is a schema-only dump, so a database built from migrations
# alone has empty `airports` / `aircraft_models`. This script copies the current
# contents of those two tables out of a populated database (prod) into a
# migration, which is what keeps a clean-room environment functional.
#
# Usage:
#   DATABASE_URL=postgres://user:pass@host:5432/db scripts/dump-reference-data.sh
#   PSQL='podman exec -i qouver-postgres' PGUSER=qouver PGDATABASE=skyward \
#     scripts/dump-reference-data.sh
#
# Only `INSERT` statements are kept: pg_dump's session boilerplate (`\restrict`,
# SETs, search_path juggling) is replaced by a hand-written header, so the
# result reads like the other migrations.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$DIR/migrations/20_reference_data_seed.sql"

if [ -n "${PSQL:-}" ]; then
  # shellcheck disable=SC2206
  DUMP=($PSQL pg_dump -U "${PGUSER:-qouver}" -d "${PGDATABASE:-skyward}")
else
  : "${DATABASE_URL:?set DATABASE_URL, or PSQL for a custom invocation}"
  DUMP=(pg_dump "$DATABASE_URL")
fi

RAW="$(mktemp)"
trap 'rm -f "$RAW"' EXIT

"${DUMP[@]}" --data-only --column-inserts --on-conflict-do-nothing \
  -t public.airports -t public.aircraft_models > "$RAW"

airports="$(grep -c '^INSERT INTO public\.airports' "$RAW" || true)"
models="$(grep -c '^INSERT INTO public\.aircraft_models' "$RAW" || true)"
if [ "$airports" -eq 0 ] || [ "$models" -eq 0 ]; then
  echo "ERROR: dump tidak berisi baris airports/aircraft_models (airports=$airports models=$models)." >&2
  echo "       Pastikan database sumber benar-benar terisi." >&2
  exit 1
fi

cat > "$OUT" <<'HEADER'
-- 20_reference_data_seed.sql — reference data for a fresh environment (refactor plan 0.9)
--
-- LATAR: `00_baseline.sql` adalah dump SCHEMA; tidak ada migrasi yang mengisi
-- `airports` dan `aircraft_models`. Prod mendapat 446 bandara dan 65 model dari
-- Supabase, jadi database yang dibangun hanya dari migrasi tidak bisa berfungsi
-- (dan migrasi 07/08/10/12 yang meng-UPDATE tabel itu menjadi no-op di sana).
-- File ini menyalin keadaan *saat ini* dari prod, sehingga koreksi 07/08/10/12
-- sudah "terbakar" di dalam datanya.
--
-- Idempoten: setiap baris memakai `ON CONFLICT DO NOTHING`, jadi menjalankannya
-- di database yang sudah terisi (prod / skyward_test) tidak mengubah apa pun.
--
-- File ini di-generate, jangan diedit manual: scripts/dump-reference-data.sh
-- Apply: make migrate  (atau psql ... < migrations/20_reference_data_seed.sql)

BEGIN;

SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;

HEADER

{
  echo "-- airports"
  grep '^INSERT INTO public\.airports' "$RAW"
  echo
  echo "-- aircraft_models"
  grep '^INSERT INTO public\.aircraft_models' "$RAW"
  echo
  echo "COMMIT;"
} >> "$OUT"

echo "==> $OUT: $airports airports + $models aircraft_models"
