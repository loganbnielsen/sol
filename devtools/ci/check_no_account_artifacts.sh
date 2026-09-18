#!/usr/bin/env bash
# HARDEN-002 run 2: the qualification tooling creates account-specific scratch
# files (a target file with the real registry and role ARNs, an operator's
# Terraform backend block). One of them was committed by a `git add -A` and had to
# be removed again. Vigilance caught it; this makes it mechanical.
#
# Rules, deliberately narrow so documented examples still pass:
#   - a real-looking 12-digit AWS account id anywhere in a target/config/IaC file
#     is an error, unless it is one of the documented placeholder accounts;
#   - qualification scratch paths must not exist in the repository at all --
#     provisioned targets, backend overrides and Terraform locks belong outside it.
#
# This is a check over what git tracks, so it runs from the real source root --
# as a CI step next to its siblings here, not as a dune runtest. Under dune the
# only root available is `_build/default`, where `git ls-files` reports nothing
# and every check below would pass vacuously.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

status=0

# 111122223333 / 123456789012 appear in docs and examples as placeholders.
placeholders='111122223333|123456789012|000000000000'

scan_files() {
  # Tracked target/config/IaC files only: those are the ones that carry a real
  # account id into the repository, and the ones an operator copies from.
  git ls-files -- '*.yml' '*.yaml' '*.tf' | grep -v '^pipeline/tickets/' || true
}

found="$(scan_files | while read -r f; do
  [ -n "$f" ] || continue
  grep -HnE '(arn:aws:[a-z-]*:[a-z0-9-]*:[0-9]{12}:|[0-9]{12}\.dkr\.ecr\.)' "$f" 2>/dev/null || true
done | grep -vE "$placeholders" || true)"

if [ -n "$found" ]; then
  echo "FAIL: real-looking AWS account id in a tracked target/config/IaC file:" >&2
  echo "$found" >&2
  echo "      Qualification artifacts must live outside the repository." >&2
  status=1
fi

# Qualification scratch must not be committable under the repository.
# .terraform.lock.hcl is deliberately tracked for the provider roots (provider
# pinning), so it is not scratch. What must never be tracked is a provisioned
# target or an operator's backend override.
scratch="$(git ls-files | grep -E '(^|/)(sol/(qual|qual2)/|backend\.tf$)' || true)"
if [ -n "$scratch" ]; then
  echo "FAIL: qualification scratch files are tracked by git:" >&2
  echo "$scratch" >&2
  echo "      Provisioned targets, backend overrides and lock files belong outside the repo;" >&2
  echo "      see HARDEN-002 (run 2) on why this is checked mechanically." >&2
  status=1
fi

if [ "$status" = "0" ]; then
  echo "qualification artifacts: no account ids or scratch files in the repository"
fi
exit "$status"
