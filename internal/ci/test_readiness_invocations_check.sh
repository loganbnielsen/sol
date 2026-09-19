#!/usr/bin/env bash
# Mutation test for check_readiness_invocations.sh (INFRA-035).
#
# A guard is only worth its runtime if it would actually have failed on the bug it
# exists for. This feeds the guard the exact invocation that shipped broken, the
# repair that replaced it, and the two ways it could pass vacuously, and asserts
# the verdict flips each time.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
guard="$here/check_readiness_invocations.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

report() {
  echo "$1" >&2
  shift
  for file in "$@"; do
    [ -f "$file" ] && sed 's/^/    /' "$file" >&2
  done
}

# 1. The bug itself: `kubectl rollout status` takes one named resource and has no
#    --all. This is the invocation that made four readiness checks impossible to
#    satisfy on real, healthy targets.
bug='cert-manager controllers\trollout\tstatus\tdeployment\t--all\t-n\tcert-manager\t--timeout=5s\n'
if printf "$bug" | "$guard" >"$tmp/bug.out" 2>&1; then
  report "the guard accepted 'rollout status deployment --all' — the exact invocation INFRA-035 exists to catch" "$tmp/bug.out"
  exit 1
fi
grep -F 'unknown flag' "$tmp/bug.out" >/dev/null || {
  report "the guard rejected the broken invocation but did not say why" "$tmp/bug.out"
  exit 1
}

# 2. The repair is accepted: waiting on the Deployment's own Available condition.
fixed='cert-manager controllers\twait\t--for=condition=Available\tdeployment\t--all\t-n\tcert-manager\t--timeout=5s\n'
if ! printf "$fixed" | "$guard" >"$tmp/fixed.out" 2>&1; then
  report "the guard rejected the repaired invocation" "$tmp/fixed.out"
  exit 1
fi

# 3. Empty input is refused, so the guard cannot pass over no invocations at all.
if printf '' | "$guard" >"$tmp/empty.out" 2>&1; then
  report "the guard passed on empty input" "$tmp/empty.out"
  exit 1
fi

# 4. A check with no argv at all is refused rather than validated as "kubectl".
if printf 'no argv\t\n' | "$guard" >"$tmp/noargv.out" 2>&1; then
  report "the guard accepted a check with no argv" "$tmp/noargv.out"
  exit 1
fi

echo "test_readiness_invocations_check: guard rejects the broken invocation, accepts the repair, and refuses vacuous passes."
