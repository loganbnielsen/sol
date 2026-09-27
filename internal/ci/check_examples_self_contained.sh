#!/usr/bin/env bash
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"

files="$(git -C "$root" ls-files -- examples |
  grep -E '\.(ya?ml|json|toml|tfvars|opam|sh)$|(^|/)(dune|dune-project|Dockerfile[^/]*)$' || true)"

if [ -z "$files" ]; then
  echo "check_examples_self_contained: no example configuration files found under examples/" >&2
  exit 1
fi

fail=0
checked=0
while IFS= read -r f; do
  checked=$((checked + 1))
  if hits="$(grep -nE '(^|[^a-zA-Z0-9_.-])internal/' "$root/$f")"; then
    while IFS= read -r hit; do
      echo "check_examples_self_contained: $f:$hit" >&2
    done <<<"$hits"
    fail=1
  fi
done <<<"$files"

if [ "$fail" -ne 0 ]; then
  echo "check_examples_self_contained: an example depends on internal/, so it cannot run from a copy of examples/ alone" >&2
  exit 1
fi
echo "check_examples_self_contained: $checked example configuration file(s) checked; none reference internal/"
