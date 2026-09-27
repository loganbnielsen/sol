#!/usr/bin/env bash
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"

spawn='Sys\.command|Unix\.system\b|Unix\.open_process|Unix\.create_process'
remove='Sys\.remove|Unix\.unlink|Unix\.rmdir'
fail=0
checked=0

scan() {
  local pattern="$1" allowed="$2" what="$3"
  shift 3
  local files
  files="$(git -C "$root" ls-files -- "$@" | grep -vE "$allowed" || true)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    checked=$((checked + 1))
    if hits="$(grep -nE "$pattern" "$root/$f")"; then
      while IFS= read -r hit; do
        echo "check_single_runner: $what: $f:$hit" >&2
      done <<<"$hits"
      fail=1
    fi
  done <<<"$files"
}

scan "$spawn" '^cli/lib/(base/sol_cli_process|cloud/sol_cli_supervised)\.ml$' \
  "spawn outside Sol_cli_process" 'cli/bin/*.ml' 'cli/lib/*.ml' 'cli/test/*.ml'
scan "$remove" '^cli/lib/base/sol_cli_fs\.ml$' \
  "removal outside Sol_cli_fs" 'cli/bin/*.ml' 'cli/lib/*.ml'

if [ "$fail" -ne 0 ]; then
  echo "check_single_runner: run processes through Sol_cli_process and remove files through Sol_cli_fs" >&2
  exit 1
fi
echo "check_single_runner: $checked file scan(s); one runner, one filesystem helper"
