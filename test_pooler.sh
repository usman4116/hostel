#!/usr/bin/env bash
set -Eeuo pipefail

: "${SUPABASE_DB_URL:?Set SUPABASE_DB_URL to the intended non-production PostgreSQL connection string.}"
: "${POOLER_CHECK_CONFIRMATION:?Set POOLER_CHECK_CONFIRMATION=CHECK_POOLER to continue.}"

if [[ "$POOLER_CHECK_CONFIRMATION" != "CHECK_POOLER" ]]; then
  echo "Pooler check guard failed."
  exit 1
fi

command -v psql >/dev/null 2>&1 || {
  echo "psql is required."
  exit 1
}

psql --no-psqlrc --set ON_ERROR_STOP=1 "$SUPABASE_DB_URL" -c "SELECT 1;" >/dev/null
echo "Pooler check completed for the configured target."
