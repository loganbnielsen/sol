#!/usr/bin/env bash
# REFAC-133: a runtime failure in the CLI is a returned [Error], never an exception
# that a caller has to know to catch (REFAC-115's rule, one level down). What may
# still raise is a *programmer* error on a static value -- a violated invariant --
# and each one is named below with its reason. Re-raising cancellation and fatal
# runtime exceptions (`... as exn -> raise exn`) is allowed anywhere.
#
# Flags `failwith`, `invalid_arg`, `raise (`, `raise <Constructor>` in cli/bin and
# cli/lib (tests are out of scope).
#
# Usage: check_no_exception_control_flow.sh [repo-root]
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"

# <path>|<fragment of the allowed line>|<why it is an invariant>
allowed=(
  "cli/lib/base/sol_cli_time.ml|is not a representable time|a float that Ptime cannot represent: the clock, not input"
  "cli/lib/base/sol_cli_yaml.ml|NUL character|the boundaries (sol.toml, migration files) refuse a NUL first"
  "cli/lib/base/sol_cli_yaml.ml|Sol_cli_yaml.render|the emitter's buffer is grown until it fits"
  "cli/lib/cloud/sol_cli_terraform.ml|must not be empty|targets are literal addresses or addresses read from state"
  "cli/lib/deploy/sol_cli_deployment_plan.ml|Error message -> invalid_arg message|a literal default quantity that fails its own parser"
  "cli/lib/deploy/sol_cli_factory.ml|length mismatch|plan and results are built one-to-one"
  "cli/lib/local/sol_cli_local_infra.ml|max_in_flight < 1|a literal concurrency bound"
)

is_allowed() {
  local file="$1" line="$2" entry path fragment
  case "$line" in *"as exn -> raise exn"*) return 0 ;; esac
  for entry in "${allowed[@]}"; do
    path="${entry%%|*}"
    fragment="${entry#*|}"
    fragment="${fragment%%|*}"
    if [ "$file" = "$path" ] && [[ "$line" == *"$fragment"* ]]; then return 0; fi
  done
  return 1
}

files="$(git -C "$root" ls-files -- 'cli/bin/*.ml' 'cli/lib/*.ml')"
if [ -z "$files" ]; then
  echo "check_no_exception_control_flow: no CLI sources found" >&2
  exit 1
fi

fail=0
checked=0
while IFS= read -r f; do
  checked=$((checked + 1))
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    if ! is_allowed "$f" "$hit"; then
      echo "check_no_exception_control_flow: $f:$hit" >&2
      fail=1
    fi
  done < <(grep -nE '\bfailwith\b|\binvalid_arg\b|\braise +(\(|[A-Z]|exn\b)' "$root/$f" || true)
done <<<"$files"

if [ "$fail" -ne 0 ]; then
  echo "check_no_exception_control_flow: return the Error instead of raising it; an invariant that may raise is named in this script with its reason" >&2
  exit 1
fi
echo "check_no_exception_control_flow: $checked CLI source file(s) checked; runtime failures are returned"
