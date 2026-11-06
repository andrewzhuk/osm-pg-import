#!/usr/bin/env bash
# Shared by entry points; no database or network operations when sourced.
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export DB_NAME="${DB_NAME:-${PGDATABASE:-ukraine}}"
export DB_USER="${DB_USER:-${PGUSER:-${USER:-postgres}}}"
export DB_HOST="${DB_HOST:-${PGHOST:-localhost}}"
export DB_PORT="${DB_PORT:-${PGPORT:-5432}}"
DB_ARGS=(-d "$DB_NAME" -U "$DB_USER" --host "$DB_HOST" --port "$DB_PORT")
export PGDATABASE="$DB_NAME" PGUSER="$DB_USER" PGHOST="$DB_HOST" PGPORT="$DB_PORT"
export SQL_SCRIPT="${SQL_SCRIPT:-$PROJECT_DIR/sql_update_ids.sql}"
LUA_SCRIPT="$PROJECT_DIR/main.lua"
REPLICATION_URL="${REPLICATION_URL:-https://download.geofabrik.de/europe/ukraine-updates}"
CACHE_MB="${CACHE_MB:-256}"

fail() { echo "Error: $*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"; }
query() { psql -X "${DB_ARGS[@]}" -v ON_ERROR_STOP=1 -Atc "$1"; }
lock_database() {
  local key
  key=$(printf '%s\n' "$DB_HOST:$DB_PORT:$DB_NAME" | cksum | awk '{print $1}')
  LOCK_DIR="${TMPDIR:-/tmp}/osm-pg-import-$key.lock"
  mkdir "$LOCK_DIR" 2>/dev/null || fail "Another import/update is running (or a stale lock exists): $LOCK_DIR"
  trap 'rmdir "$LOCK_DIR"' EXIT
}
check_schema() {
  [[ "$(query "SELECT to_regclass('public.osm_pg_import_meta') IS NOT NULL")" == t ]] \
    || fail 'Legacy/incomplete database. Import into a new database with run_osm_import.sh; existing data was not changed.'
  [[ "$(query "SELECT value FROM public.osm_pg_import_meta WHERE key = 'schema_version'")" == 2 ]] \
    || fail 'Unsupported database schema; use a fresh database.'
}
init_replication() {
  # A custom regional service is paired with the imported dataset timestamp.
  # Never reset replication state automatically on an ordinary update.
  local extra=(--server "$REPLICATION_URL")
  if [[ -n "${REPLICATION_START_AT:-}" ]]; then extra+=(--start-at "$REPLICATION_START_AT"); fi
  osm2pgsql-replication init "${DB_ARGS[@]}" "${extra[@]}"
}
