#!/usr/bin/env bash
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"

files="$(git -C "$root" ls-files -- 'cli/bin/*.ml' 'cli/lib/*.ml')"
if [ -z "$files" ]; then
  echo "check_json_decode_boundary: no CLI sources found" >&2
  exit 1
fi

fail=0
checked=0
while IFS= read -r f; do
  checked=$((checked + 1))
  if hits="$(grep -nE 'Yojson\.(Safe|Basic)\.Util' "$root/$f")"; then
    while IFS= read -r hit; do
      echo "check_json_decode_boundary: $f:$hit" >&2
    done <<<"$hits"
    fail=1
  fi
done <<<"$files"

if [ "$fail" -ne 0 ]; then
  echo "check_json_decode_boundary: read JSON through Sol_cli_json (total field access, errors not exceptions)" >&2
  exit 1
fi
echo "check_json_decode_boundary: $checked CLI source file(s) checked; JSON is read through Sol_cli_json"
