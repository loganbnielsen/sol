#!/usr/bin/env bash

set -euo pipefail

command -v kubectl >/dev/null 2>&1 || {
  echo "check_readiness_invocations: kubectl is required to validate readiness probe argv." >&2
  echo "  Install the version pinned in .github/workflows/ci.yml (dogfood job)." >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

input="$tmp/invocations.tsv"
cat >"$input"

lines=0
while IFS= read -r line; do
  [ -n "$line" ] && lines=$((lines + 1))
done <"$input"
if [ "$lines" -eq 0 ]; then
  echo "check_readiness_invocations: no invocations were supplied to validate." >&2
  exit 1
fi

parse_error='unknown flag|unknown shorthand flag|unknown command|invalid argument|^usage:|for usage'

fail=0
checked=0
while IFS=$'\t' read -r name argv; do
  [ -n "${name:-}" ] || continue
  IFS=$'\t' read -r -a args <<<"$argv"
  if [ "${#args[@]}" -eq 0 ]; then
    echo "check_readiness_invocations: '$name' has no argv." >&2
    fail=1
    continue
  fi
  out="$tmp/out.$checked"
  KUBECONFIG=/dev/null kubectl "${args[@]}" >"$out" 2>&1 || true
  checked=$((checked + 1))
  if grep -qiE "$parse_error" "$out"; then
    echo "check_readiness_invocations: '$name' is not a valid kubectl invocation:" >&2
    sed 's/^/    /' "$out" >&2
    printf '    argv: kubectl' >&2
    printf ' %q' "${args[@]}" >&2
    printf '\n' >&2
    fail=1
  fi
done <"$input"

if [ "$fail" -ne 0 ]; then
  exit 1
fi

client="$(kubectl version --client -o json 2>/dev/null | sed -n 's/.*"gitVersion": *"\([^"]*\)".*/\1/p' | head -1)"
echo "check_readiness_invocations: $checked readiness invocations accepted by kubectl ${client:-unknown}"
