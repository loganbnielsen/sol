#!/usr/bin/env bash
# Validate the readiness checks' kubectl invocations against a real kubectl
# (INFRA-035).
#
# Why this exists: readiness is what licenses the PlatformInstalling -> Ready
# transition, and every check is a hand-built kubectl invocation in
# sol_cli_cloud_lifecycle.ml. Nothing validated those argv against kubectl, so
# `kubectl rollout status deployment --all` shipped — a flag kubectl does not
# have — and four checks failed with `unknown flag: --all` on real targets.
# Because readiness requires *zero* unmet checks, no target could ever reach
# Ready, and the failure presented as nine unhealthy components.
#
# The offline lifecycle harness cannot cover this. Its fake kubectl accepts any
# argv, so it asserts what Sol does with kubectl's *output* and can never assert
# that kubectl would accept the *input*.
#
# How the argv is validated without a cluster: kubectl parses its flags before it
# contacts anything, so an invocation run with no kubeconfig proves the argv was
# accepted — a parse error is distinguishable from the connection error that
# follows. No cluster is contacted and nothing is mutated.
#
# Input: tab separated `<backend> \t <check name> \t <argv item> ...`, one check
# per line, printed by cli/sol/test/print_readiness_invocations.ml.
#
# Usage:
#   internal/ci/check_readiness_invocations.sh < invocations.tsv

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

# A guard that passes on empty input is not a guard. If the printer ever produced
# nothing — a build change, a dropped rule — this must fail loudly rather than
# report success over no invocations at all.
lines=0
while IFS= read -r line; do
  [ -n "$line" ] && lines=$((lines + 1))
done <"$input"
if [ "$lines" -eq 0 ]; then
  echo "check_readiness_invocations: no invocations were supplied to validate." >&2
  exit 1
fi

# kubectl's own wording for "I could not parse this". Matching on the phrases
# rather than an exit code is deliberate: a valid invocation also fails here, on
# the connection, and that must not be mistaken for a rejected argument.
parse_error='unknown flag|unknown shorthand flag|unknown command|invalid argument|^usage:|for usage'

fail=0
checked=0
while IFS=$'\t' read -r backend name argv; do
  [ -n "${name:-}" ] || continue
  IFS=$'\t' read -r -a args <<<"$argv"
  if [ "${#args[@]}" -eq 0 ]; then
    echo "check_readiness_invocations: '$name' ($backend) has no argv." >&2
    fail=1
    continue
  fi
  out="$tmp/out.$checked"
  KUBECONFIG=/dev/null kubectl "${args[@]}" >"$out" 2>&1 || true
  checked=$((checked + 1))
  if grep -qiE "$parse_error" "$out"; then
    echo "check_readiness_invocations: '$name' ($backend) is not a valid kubectl invocation:" >&2
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

# Which kubectl accepted them is part of the result: validity is a property of a
# version, so the evidence should name the one that was checked.
client="$(kubectl version --client -o json 2>/dev/null | sed -n 's/.*"gitVersion": *"\([^"]*\)".*/\1/p' | head -1)"
echo "check_readiness_invocations: $checked readiness invocations accepted by kubectl ${client:-unknown}"
