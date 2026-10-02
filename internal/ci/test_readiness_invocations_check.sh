#!/usr/bin/env bash

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
guard="$here/context/check_readiness_invocations.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

report() {
  echo "$1" >&2
  shift
  for file in "$@"; do
    [ -f "$file" ] && sed 's/^/    /' "$file" >&2
  done
}

bug='cert-manager controllers\trollout\tstatus\tdeployment\t--all\t-n\tcert-manager\t--timeout=5s\n'
if printf "$bug" | "$guard" >"$tmp/bug.out" 2>&1; then
  report "the guard accepted 'rollout status deployment --all' — the exact invocation INFRA-035 exists to catch" "$tmp/bug.out"
  exit 1
fi
grep -F 'unknown flag' "$tmp/bug.out" >/dev/null || {
  report "the guard rejected the broken invocation but did not say why" "$tmp/bug.out"
  exit 1
}

fixed='cert-manager controllers\twait\t--for=condition=Available\tdeployment\t--all\t-n\tcert-manager\t--timeout=5s\n'
if ! printf "$fixed" | "$guard" >"$tmp/fixed.out" 2>&1; then
  report "the guard rejected the repaired invocation" "$tmp/fixed.out"
  exit 1
fi

if printf '' | "$guard" >"$tmp/empty.out" 2>&1; then
  report "the guard passed on empty input" "$tmp/empty.out"
  exit 1
fi

if printf 'no argv\t\n' | "$guard" >"$tmp/noargv.out" 2>&1; then
  report "the guard accepted a check with no argv" "$tmp/noargv.out"
  exit 1
fi

echo "test_readiness_invocations_check: guard rejects the broken invocation, accepts the repair, and refuses vacuous passes."
