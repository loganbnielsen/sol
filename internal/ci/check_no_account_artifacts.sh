#!/usr/bin/env bash
# HARDEN-002 run 2: the qualification tooling creates account-specific scratch
# files (a target file with the real registry and role ARNs, an operator's
# Terraform backend block). One of them was committed by a `git add -A` and had to
# be removed again. Vigilance caught it; this makes it mechanical.
#
# Rules, deliberately high-signal so documented examples still pass:
#   - a real-looking 12-digit AWS account id in any tracked text file is an
#     error, unless it is one of the documented placeholder accounts. An id is
#     matched when it is account-*shaped*: in an `arn:aws:...:<id>:` ARN, in an
#     ECR registry host, after the word "account", or adjacent (in either order)
#     to a qualification qualifier -- the word "aws", a region token, or an
#     `arn:` fragment. A bare 12-digit number with no such qualifier is still not
#     matched: a GitHub run id, a hash prefix and a timestamp fragment are all
#     digit runs, and none of them sits next to a qualifier. FND-0015: a bare id
#     in prose sat in this repository undetected until this rule, so the
#     asymmetry is deliberate -- a false positive costs a minute, a false
#     negative is a permanent leak in a public repository;
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

# What a bare account id has to sit next to, in either order: the word
# "account", the word "aws" (letter-bounded, so "flaws" is not one), an `arn:`
# fragment, or an AWS region token. The region alternatives are the actual AWS
# prefixes so a workload name like `my-app-name-1` is not mistaken for a region.
account_qualifier='([Aa]ccount|(^|[^A-Za-z])[Aa][Ww][Ss]|arn:|(us|eu|ap|sa|ca|me|af|cn|il)(-gov)?-[a-z]+-[0-9])'

# Every tracked text file, regardless of extension: the real leak this guard
# missed first was a bare account id in a planning .md, not in a target/.tf. The
# `(^|[^0-9/])` before each bare-id alternative is what keeps a GitHub run id in
# its URL (`.../actions/runs/<id>`) out: an account id in prose is not a path
# segment.
found="$(git grep -nI -E "(arn:aws:[a-zA-Z0-9-]*:[a-zA-Z0-9-]*:[0-9]{12}:|[0-9]{12}\\.dkr\\.ecr|[Aa]ccount[^0-9]{0,12}[0-9]{12}|(^|[^0-9/])[0-9]{12}[^0-9]{0,16}${account_qualifier}|${account_qualifier}[^0-9]{0,16}(^|[^0-9/])[0-9]{12})" 2>/dev/null | grep -vE "$placeholders" || true)"

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
