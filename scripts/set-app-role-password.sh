#!/usr/bin/env bash
# Set password untuk role `skyward_app` — langkah operator, sengaja di luar file
# migrasi supaya tidak ada kredensial yang masuk git (refactor plan 0.2c).
#
# Pemakaian (lokal, lewat tunnel ke VPS):
#   APP_DB_PASSWORD='…' \
#   DATABASE_URL=postgres://qouver@127.0.0.1:15432/skyward \
#     scripts/set-app-role-password.sh
#
# Pemakaian (VPS, podman):
#   APP_DB_PASSWORD='…' \
#   PSQL='podman exec -i qouver-postgres psql -U qouver -d skyward' \
#     scripts/set-app-role-password.sh
#
# Password dibaca dari environment dan dikirim lewat stdin psql — bukan argv,
# jadi tidak muncul di `ps` maupun riwayat shell, dan tidak pernah dicetak.
set -euo pipefail

if [ -n "${PSQL:-}" ]; then
  # shellcheck disable=SC2206
  PSQL_CMD=($PSQL)
else
  : "${DATABASE_URL:?set DATABASE_URL, atau PSQL untuk pemanggilan psql khusus}"
  PSQL_CMD=(psql "$DATABASE_URL")
fi

: "${APP_DB_PASSWORD:?set APP_DB_PASSWORD}"

"${PSQL_CMD[@]}" -q -v ON_ERROR_STOP=1 -v pw="$APP_DB_PASSWORD" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'skyward_app') THEN
    RAISE EXCEPTION 'role skyward_app belum ada — jalankan `make migrate` dulu';
  END IF;
END
$$;
ALTER ROLE skyward_app WITH LOGIN PASSWORD :'pw';
SQL

echo "==> password role skyward_app diperbarui"
