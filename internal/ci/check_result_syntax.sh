#!/usr/bin/env bash
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"

files="$(git -C "$root" ls-files -- '*.ml')"
if [ -z "$files" ]; then
  echo "check_result_syntax: no OCaml sources found" >&2
  exit 1
fi

fail=0
checked=0
while IFS= read -r f; do
  checked=$((checked + 1))
  if hits="$(grep -nE 'let \( let\* \) *= *Result\.bind' "$root/$f")"; then
    while IFS= read -r hit; do
      echo "check_result_syntax: $f:$hit" >&2
    done <<<"$hits"
    fail=1
  fi
done <<<"$files"

if [ "$fail" -ne 0 ]; then
  echo "check_result_syntax: use Result.Syntax instead of a hand-written let*" >&2
  exit 1
fi
echo "check_result_syntax: $checked OCaml file(s) checked; no hand-written let*"
