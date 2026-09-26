#!/usr/bin/env bash
# Mutation test for the account-artifact guard: prove it can fail, not just pass
# on a clean tree. Mirrors test_public_cloud_lifecycle.sh.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
guard="$root/internal/ci/check_no_account_artifacts.sh"

"$guard" "$root" >/dev/null

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
git -C "$tmp" -c user.email=test@example.invalid -c user.name=test config user.email test@example.invalid
git -C "$tmp" -c user.email=test@example.invalid -c user.name=test config user.name test

# A documented placeholder must pass.
printf 'The example account is 123456789012.\n' >"$tmp/notes.md"
git -C "$tmp" add -A
"$guard" "$tmp" >/dev/null

# A real-looking account id must fail, even in a plain markdown file. Assemble
# the id from a variable so this script -- which the guard also scans, since it
# is tracked text -- does not itself carry an account-shaped literal.
fake_id="987654321098"
printf 'AWS account: %s\n' "$fake_id" >>"$tmp/notes.md"
git -C "$tmp" add -A
if "$guard" "$tmp" >/dev/null 2>&1; then
  echo "guard accepted a real-looking account id in a tracked markdown file" >&2
  exit 1
fi
rm -f "$tmp/notes.md"

# FND-0015: a *bare* account id in prose -- no `account`, no ARN, no ECR host --
# must fail when it is adjacent to a region token. This is the exact shape that
# sat undetected in HARDEN-002.md.
bare_id="246813579024"
printf 'Target `sol-qual7-ab12cd34` (production-single-region/v1, %s / us-east-1).\n' \
  "$bare_id" >"$tmp/prose.md"
git -C "$tmp" add -A
if "$guard" "$tmp" >/dev/null 2>&1; then
  echo "guard accepted a bare account id adjacent to a region token" >&2
  exit 1
fi
rm -f "$tmp/prose.md"

# ... but a 12-digit number with no qualifier is not an account id, and must not
# false-positive. The three shapes: a GitHub run id (notably in its URL, where
# the id is a path segment, which is why the pattern excludes a preceding `/`),
# a timestamp fragment, and a hash prefix.
run_id="356549406961"
printf 'run https://github.com/loganbnielsen/sol/actions/runs/%s in us-east-1\n' \
  "$run_id" >"$tmp/numbers.md"
printf 'timestamp %s sha a1b2c3d4e5f6 %s\n' "$bare_id" "$run_id" >>"$tmp/numbers.md"
git -C "$tmp" add -A
"$guard" "$tmp" >/dev/null

# The word "account" followed by an id still fails, as it always has.
printf 'account %s was used\n' "$bare_id" >"$tmp/account.md"
git -C "$tmp" add -A
if "$guard" "$tmp" >/dev/null 2>&1; then
  echo "guard accepted an 'account <id>' phrase" >&2
  exit 1
fi


git -C "$tmp" rm -q --cached "$tmp/account.md"
rm -f "$tmp/account.md"

# FEAT-100: a tracked sol/environments.local.yml, the file that holds a provisioned
# target's real identity, must fail; so must a per-attempt sol/qualN/ directory
# (INFRA-084 keys each attempt), which the old qual|qual2 pattern missed.
for scratch in "examples/app/sol/environments.local.yml" "examples/app/sol/qual9/gcp/us-central1.yml"; do
  mkdir -p "$tmp/$(dirname "$scratch")"
  printf 'x: 1\n' >"$tmp/$scratch"
  git -C "$tmp" add -A
  if "$guard" "$tmp" >/dev/null 2>&1; then
    echo "guard accepted a tracked $scratch" >&2
    exit 1
  fi
  git -C "$tmp" rm -q --cached "$tmp/$scratch"
  rm -f "$tmp/$scratch"
done
# A tracked sol/environments.yml (the committed, account-free file) must pass.
mkdir -p "$tmp/examples/app/sol"
printf 'prod:\n  targets:\n    aws/us-east-1:\n' >"$tmp/examples/app/sol/environments.yml"
git -C "$tmp" add -A
"$guard" "$tmp" >/dev/null
echo "account-artifact guard mutation test: ok"
