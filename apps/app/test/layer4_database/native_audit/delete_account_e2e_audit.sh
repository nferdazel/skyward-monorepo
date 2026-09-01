#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

: "${SUPABASE_URL:?SUPABASE_URL is required}"
: "${SUPABASE_KEY:?SUPABASE_KEY is required}"

for tool in curl jq supabase; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
done

suffix="$(date +%s)"
username="auditdelete${suffix}"
password="AuditPass123!"
company_name="Audit Delete Airways ${suffix}"
ceo_name="Audit Delete CEO"
email="${username}@skyward.sachiel.id"

register_payload="$(jq -n \
  --arg username "$username" \
  --arg password "$password" \
  --arg companyName "$company_name" \
  --arg ceoName "$ceo_name" \
  '{username:$username,password:$password,companyName:$companyName,ceoName:$ceoName}')"

register_response="$(curl -sS -X POST "${SUPABASE_URL}/functions/v1/register-with-username" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Content-Type: application/json" \
  --data "$register_payload")"

register_success="$(printf '%s' "$register_response" | jq -r '.success // false')"
if [[ "$register_success" != "true" ]]; then
  echo "Registration failed: $register_response" >&2
  exit 1
fi

login_response="$(curl -sS -X POST "${SUPABASE_URL}/auth/v1/token?grant_type=password" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Content-Type: application/json" \
  --data "{\"email\":\"${email}\",\"password\":\"${password}\"}")"

access_token="$(printf '%s' "$login_response" | jq -r '.access_token // empty')"
if [[ -z "$access_token" ]]; then
  echo "Login failed: $login_response" >&2
  exit 1
fi

delete_response="$(curl -sS -X POST "${SUPABASE_URL}/functions/v1/delete-account" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${access_token}" \
  -H "Content-Type: application/json")"

delete_success="$(printf '%s' "$delete_response" | jq -r '.success // false')"
if [[ "$delete_success" != "true" ]]; then
  echo "delete-account failed: $delete_response" >&2
  exit 1
fi

verification_sql="SELECT 'public.users' AS scope, COUNT(*) AS remaining_rows FROM public.users WHERE username = '${username}' UNION ALL SELECT 'auth.users' AS scope, COUNT(*) AS remaining_rows FROM auth.users WHERE email = '${email}';"
verification_json="$(SUPABASE_DISABLE_TELEMETRY=1 supabase db query --linked "$verification_sql" -o json)"

public_remaining="$(printf '%s' "$verification_json" | jq -r '.rows[] | select(.scope == "public.users") | .remaining_rows')"
auth_remaining="$(printf '%s' "$verification_json" | jq -r '.rows[] | select(.scope == "auth.users") | .remaining_rows')"

if [[ "$public_remaining" != "0" || "$auth_remaining" != "0" ]]; then
  echo "Delete verification failed for ${username}" >&2
  echo "$verification_json" >&2
  exit 1
fi

echo "Delete-account E2E audit passed"
echo "username=${username}"
echo "email=${email}"
SUPABASE_DISABLE_TELEMETRY=1 supabase db query --linked "$verification_sql" -o table
