#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/scripts/common.sh"
[[ $# == 0 ]] || fail 'Usage: bash run_osm_import.sh (configure via environment; see README)'
OSM_FILE="${OSM_FILE:-$PROJECT_DIR/ukraine-latest.osm.pbf}"
[[ "$OSM_FILE" = /* ]] || OSM_FILE="$PWD/$OSM_FILE"
[[ "$CACHE_MB" =~ ^[0-9]+$ ]] || fail 'CACHE_MB must be a nonnegative integer'
for cmd in osm2pgsql psql createdb; do require_command "$cmd"; done
if [[ "${INIT_REPLICATION:-0}" == 1 ]]; then require_command osm2pgsql-replication; fi

# Downloads are opt-in; missing input fails before any database changes.
if [[ ! -s "$OSM_FILE" ]]; then
  [[ "${DOWNLOAD_OSM:-0}" == 1 ]] || fail "Input file missing/empty: $OSM_FILE. Supply OSM_FILE; downloading requires DOWNLOAD_OSM=1."
  require_command curl
  mkdir -p "$(dirname -- "$OSM_FILE")"
  download_tmp=$(mktemp "$OSM_FILE.download.XXXXXX")
  trap 'rm -f "$download_tmp"' EXIT
  curl --fail --location --connect-timeout 15 --retry 2 \
    "${OSM_URL:-https://download.geofabrik.de/europe/ukraine-latest.osm.pbf}" -o "$download_tmp"
  [[ -s "$download_tmp" ]] || fail 'Downloaded file is empty'
  mv -- "$download_tmp" "$OSM_FILE"
  trap - EXIT
fi
lock_database
# Refuse to overwrite any existing user tables, including legacy imports.
exists=$(psql -X -d postgres -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" \
  -v ON_ERROR_STOP=1 -v target_db="$DB_NAME" -At <<'SQL'
SELECT EXISTS(SELECT FROM pg_database WHERE datname = :'target_db');
SQL
)
if [[ "$exists" == t ]]; then
  has_objects=$(query "
    SELECT EXISTS(
      SELECT FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
        AND n.nspname !~ '^pg_toast'
        AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
        AND NOT EXISTS(
          SELECT FROM pg_depend d WHERE d.classid = 'pg_class'::regclass
            AND d.objid = c.oid AND d.deptype = 'e'
        )
    )")
  [[ "$has_objects" == f ]] \
    || fail 'Database already contains user objects. Choose a new DB_NAME; import will not overwrite it.'
else
  createdb -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" -- "$DB_NAME"
fi
query 'CREATE EXTENSION IF NOT EXISTS postgis;' >/dev/null
osm2pgsql "${DB_ARGS[@]}" --create --slim -C "$CACHE_MB" \
  --output=flex --style="$LUA_SCRIPT" "$OSM_FILE"
bash "$PROJECT_DIR/scripts/postprocess.sh"
if [[ "${INIT_REPLICATION:-0}" == 1 ]]; then init_replication; fi
echo 'Import and SQL processing completed successfully.'
