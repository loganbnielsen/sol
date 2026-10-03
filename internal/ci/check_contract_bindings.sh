#!/usr/bin/env bash
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CHECKOUT="${CONTRACT_BINDINGS_CHECKOUT:-$ROOT}"
BIN="$ROOT/_build/default/cli/bin/main.exe"

if [ ! -x "$BIN" ]; then
  echo "contract bindings: the sol binary is not built at $BIN" >&2
  exit 1
fi

status=0
for workspace in examples/pluto platform/shared/templates/workspace; do
  if [ ! -d "$CHECKOUT/$workspace" ]; then
    echo "contract bindings: $workspace is missing" >&2
    status=1
    continue
  fi
  if ! (cd "$CHECKOUT/$workspace" && SOL_HOME="$ROOT" "$BIN" contract generate --check); then
    status=1
  fi
done
exit "$status"
