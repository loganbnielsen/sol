#!/usr/bin/env bash
# REFAC-131: Sol builds every Kubernetes manifest as a value and renders it with
# one emitter (Sol_cli_yaml for YAML, Yojson for JSON). A manifest written as text
# -- a {|apiVersion: ...%s|} template, or a sprintf'd {"apiVersion":"%s"} -- puts
# values into it unescaped, so a quote or a newline in a value changes the
# document's structure, and a value like `true` or `1.10` changes type.
#
# Flags, in CLI sources (cli/bin, cli/lib; tests are out of scope):
#   apiVersion:          a YAML manifest key written as text
#   "apiVersion":        a JSON manifest key written as text (escaped or not)
# The value forms -- ("apiVersion", string "v1") and ("apiVersion", `String "v1")
# -- do not match.
#
# Usage: check_manifests_are_values.sh [repo-root]
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
