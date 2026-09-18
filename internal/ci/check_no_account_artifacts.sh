#!/usr/bin/env bash
# HARDEN-002 run 2: the qualification tooling creates account-specific scratch
# files (a target file with the real registry and role ARNs, an operator's
# Terraform backend block). One of them was committed by a `git add -A` and had to
# be removed again. Vigilance caught it; this makes it mechanical.
#
# Rules, deliberately high-signal so documented examples still pass:
#   - a real-looking 12-digit AWS account id in any tracked text file is an
#     error, unless it is one of the documented placeholder accounts. The
#     patterns are account-shaped (an `arn:aws:...:<id>:` ARN, an account id in
#     an ECR registry host, or the word "account" followed by an id) rather than
#     a bare 12-digit number, which would false-positive on GitHub run ids;
#   - qualification scratch paths must not exist in the repository at all --
#     provisioned targets, backend overrides and Terraform locks belong outside it.
#
# Usage: check_no_account_artifacts.sh [repo-root]
#
# This is a check over what git tracks, so it runs from the real source root --
# as a CI step next to its siblings here, not as a dune runtest. Under dune the
# only root available is `_build/default`, where `git ls-files` reports nothing
# and every check below would pass vacuously.
set -euo pipefail

root="${1:-$(git rev-parse --show-toplevel)}"
cd "$root"

status=0

# 111122223333 / 123456789012 / 000000000000 appear in docs and examples as
# placeholders.
placeholders='111122223333|123456789012|000000000000'

# Every tracked text file, regardless of extension: the real leak this guard
# missed first was a bare account id in a planning .md, not in a target/.tf.
found="$(git grep -nI -E '(arn:aws:[a-zA-Z0-9-]*:[a-zA-Z0-9-]*:[0-9]{12}:|[0-9]{12}\.dkr\.ecr|[Aa]ccount[^0-9]{0,12}[0-9]{12})' 2>/dev/null | grep -vE "$placeholders" || true)"

if [ -n "$found" ]; then
  echo "FAIL: real-looking AWS account id in a tracked file:" >&2
  echo "$found" >&2
  echo "      Tracked material must not carry a real account id; use a documented" >&2
  echo "      placeholder or keep qualification artifacts outside the repository." >&2
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
  echo "      Provisioned targets and backend overrides belong outside the repo;" >&2
  echo "      see HARDEN-002 (run 2) on why this is checked mechanically." >&2
  status=1
fi

if [ "$status" = "0" ]; then
  echo "qualification artifacts: no account ids or scratch files in the repository"
fi
exit "$status"
