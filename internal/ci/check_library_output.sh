#!/usr/bin/env bash
# REFAC-135: library code does not print. It reports through Sol_cli_report
# (Logs underneath), and the CLI's edge decides where a report goes -- so a
# warning is something a caller or a test can see, not text that vanished into
# stderr.
#
# Flags printing in cli/lib outside the two modules that are the edge:
#   cli/lib/base/sol_cli_report.ml   the terminal reporter itself
#   cli/lib/base/sol_cli_exit.ml     a command's exit, which prints its failure
#
# Usage: check_library_output.sh [repo-root]
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"

files="$(git -C "$root" ls-files -- 'cli/lib/*.ml' |
  grep -vE '^cli/lib/base/sol_cli_(report|exit)\.ml$' || true)"
if [ -z "$files" ]; then
  echo "check_library_output: no library sources found under cli/lib" >&2
  exit 1
fi

pattern='Printf\.e?printf|\bprint_(endline|string|newline|char|int)\b|\bprerr_(endline|string|newline)\b|Format\.e?printf|output_string (stdout|stderr)'
fail=0
checked=0
while IFS= read -r f; do
  checked=$((checked + 1))
  if hits="$(grep -nE "$pattern" "$root/$f")"; then
    while IFS= read -r hit; do
      echo "check_library_output: $f:$hit" >&2
    done <<<"$hits"
    fail=1
  fi
done <<<"$files"

if [ "$fail" -ne 0 ]; then
  echo "check_library_output: report through Sol_cli_report (app / warn / err); the CLI's edge prints" >&2
  exit 1
fi
echo "check_library_output: $checked library file(s) checked; none prints"
