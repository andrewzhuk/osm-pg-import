#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
require_command psql
# Replication supplies sequence/timestamp as arguments; SQL only needs the DB.
psql -X "${DB_ARGS[@]}" -v ON_ERROR_STOP=1 --single-transaction -f "$SQL_SCRIPT"
