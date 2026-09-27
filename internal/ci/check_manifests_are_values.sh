#!/usr/bin/env bash
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"

files="$(git -C "$root" ls-files -- 'cli/bin/*.ml' 'cli/lib/*.ml')"
if [ -z "$files" ]; then
  echo "check_manifests_are_values: no CLI sources found under cli/" >&2
  exit 1
fi

pattern='apiVersion:|\\?"apiVersion\\?":'
fail=0
checked=0
while IFS= read -r f; do
  checked=$((checked + 1))
  if hits="$(grep -nE "$pattern" "$root/$f")"; then
    while IFS= read -r hit; do
      echo "check_manifests_are_values: $f:$hit" >&2
    done <<<"$hits"
    fail=1
  fi
done <<<"$files"

if [ "$fail" -ne 0 ]; then
  echo "check_manifests_are_values: build the manifest as a value (Sol_cli_yaml, Yojson), not as text" >&2
  exit 1
fi
echo "check_manifests_are_values: $checked CLI source file(s) checked; no manifest is written as text"
