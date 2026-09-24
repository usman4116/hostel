#!/usr/bin/env bash
set -Eeuo pipefail

: "${SUPABASE_DB_URL:?Set SUPABASE_DB_URL to the intended non-production PostgreSQL connection string.}"
: "${MIGRATION_TARGET:?Set MIGRATION_TARGET to an explicit environment name.}"
: "${ALLOW_REMOTE_MIGRATIONS:?Set ALLOW_REMOTE_MIGRATIONS=YES only after reviewing the target.}"
: "${MIGRATION_CONFIRMATION:?Set MIGRATION_CONFIRMATION=APPLY_MIGRATIONS to continue.}"

if [[ "$MIGRATION_TARGET" == "production" || "$MIGRATION_TARGET" == "prod" ]]; then
  echo "Refusing to target production. Use a reviewed non-production environment."
  exit 1
fi

if [[ "$ALLOW_REMOTE_MIGRATIONS" != "YES" || "$MIGRATION_CONFIRMATION" != "APPLY_MIGRATIONS" ]]; then
  echo "Migration guard failed. No migrations were applied."
  exit 1
fi

command -v psql >/dev/null 2>&1 || {
  echo "psql is required. No migrations were applied."
  exit 1
}

shopt -s nullglob
files=(supabase/migrations/*.sql)
(( ${#files[@]} > 0 )) || {
  echo "No migration files found."
  exit 1
}

mapfile -t files < <(printf '%s\n' "${files[@]}" | sort)
for file in "${files[@]}"; do
  echo "Applying $(basename "$file") to target '$MIGRATION_TARGET'..."
  psql --no-psqlrc --set ON_ERROR_STOP=1 "$SUPABASE_DB_URL" -f "$file"
done

echo "Migrations completed for target '$MIGRATION_TARGET'."
