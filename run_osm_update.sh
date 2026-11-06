#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/scripts/common.sh"
[[ $# == 0 || ( $# == 1 && "$1" == --init ) ]] || fail 'Usage: bash run_osm_update.sh [--init]'
[[ "$CACHE_MB" =~ ^[0-9]+$ ]] || fail 'CACHE_MB must be a nonnegative integer'
MAX_DIFF_SIZE="${MAX_DIFF_SIZE:-10}"
[[ "$MAX_DIFF_SIZE" =~ ^[1-9][0-9]*$ ]] || fail 'MAX_DIFF_SIZE must be a positive integer (MB)'
for cmd in osm2pgsql osm2pgsql-replication psql; do require_command "$cmd"; done
lock_database
check_schema
if [[ "${1:-}" == --init ]]; then
  init_replication
else
  # Run postprocessing BEFORE the replication tool advances its checkpoint.
  # A SQL failure makes the update fail and allows the same diff to be retried.
  osm2pgsql-replication update "${DB_ARGS[@]}" --max-diff-size "$MAX_DIFF_SIZE" \
    --post-processing "$PROJECT_DIR/scripts/postprocess.sh" -- \
    --slim -C "$CACHE_MB" --output=flex --style="$LUA_SCRIPT"
fi
