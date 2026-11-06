#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
for runtime in lua luajit; do
  if command -v "$runtime" >/dev/null 2>&1; then
    LUA="$runtime"
    break
  fi
done
[[ -n "${LUA:-}" ]] || { echo 'Install Lua or LuaJIT to run transformation tests.' >&2; exit 1; }
bash -n "$ROOT"/run_osm_*.sh "$ROOT"/scripts/*.sh
cd "${TMPDIR:-/tmp}"
"$LUA" "$ROOT/tests/test_names.lua" "$ROOT"
python3 "$ROOT/tests/test_scripts.py"
