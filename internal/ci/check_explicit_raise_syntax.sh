#!/usr/bin/env bash
set -euo pipefail

# This guard checks one narrow syntactic property in CLI sources: no unlisted
# `failwith`, `invalid_arg`, or `raise` appears outside the named invariants below.
#
# It is deliberately *not* proof that runtime failures are returned, that resources are
# closed, or that every execution path obeys a sequence. An operation can raise without
# any of this syntax (for example a channel write), and the allow-listed invariants are
# permitted to raise. Run-log exception and resource policy is owned by #1161.

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"

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
  echo "check_explicit_raise_syntax: no CLI sources found" >&2
  exit 1
fi

fail=0
checked=0
while IFS= read -r f; do
  checked=$((checked + 1))
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    if ! is_allowed "$f" "$hit"; then
      echo "check_explicit_raise_syntax: $f:$hit" >&2
      fail=1
    fi
  done < <(grep -nE '\bfailwith\b|\binvalid_arg\b|\braise +(\(|[A-Z]|exn\b)' "$root/$f" || true)
done <<<"$files"

if [ "$fail" -ne 0 ]; then
  echo "check_explicit_raise_syntax: use an Error instead of raising, or add the invariant to this guard's named allow-list with its reason" >&2
  exit 1
fi
echo "check_explicit_raise_syntax: $checked CLI source file(s) checked; no unlisted explicit failwith/invalid_arg/raise syntax (a syntax check, not proof that runtime failures are returned or cleanup occurs)"
