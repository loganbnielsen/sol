#!/usr/bin/env bash
set -euo pipefail
CI="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$CI/lib/scratch_repo.sh"

root="$(git rev-parse --show-toplevel)"
guard="$CI/always/check_no_account_artifacts.sh"

"$guard" "$root" >/dev/null

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
scratch_repo_init "$tmp"
git -C "$tmp" -c user.email=test@example.invalid -c user.name=test config user.email test@example.invalid
git -C "$tmp" -c user.email=test@example.invalid -c user.name=test config user.name test

printf 'The example account is 123456789012.\n' >"$tmp/notes.md"
git -C "$tmp" add -A
"$guard" "$tmp" >/dev/null

fake_id="987654321098"
printf 'AWS account: %s\n' "$fake_id" >>"$tmp/notes.md"
git -C "$tmp" add -A
if "$guard" "$tmp" >/dev/null 2>&1; then
  echo "guard accepted a real-looking account id in a tracked markdown file" >&2
  exit 1
fi
rm -f "$tmp/notes.md"

bare_id="246813579024"
printf 'Target `sol-qual7-ab12cd34` (production-single-region/v1, %s / us-east-1).\n' \
  "$bare_id" >"$tmp/prose.md"
git -C "$tmp" add -A
if "$guard" "$tmp" >/dev/null 2>&1; then
  echo "guard accepted a bare account id adjacent to a region token" >&2
  exit 1
fi
rm -f "$tmp/prose.md"

run_id="356549406961"
printf 'run https://github.com/sol-fab/sol/actions/runs/%s in us-east-1\n' \
  "$run_id" >"$tmp/numbers.md"
printf 'timestamp %s sha a1b2c3d4e5f6 %s\n' "$bare_id" "$run_id" >>"$tmp/numbers.md"
git -C "$tmp" add -A
"$guard" "$tmp" >/dev/null

printf 'account %s was used\n' "$bare_id" >"$tmp/account.md"
git -C "$tmp" add -A
if "$guard" "$tmp" >/dev/null 2>&1; then
  echo "guard accepted an 'account <id>' phrase" >&2
  exit 1
fi


git -C "$tmp" rm -q --cached "$tmp/account.md"
rm -f "$tmp/account.md"

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
mkdir -p "$tmp/examples/app/sol"
printf 'prod:\n  targets:\n    aws/us-east-1:\n' >"$tmp/examples/app/sol/environments.yml"
git -C "$tmp" add -A
"$guard" "$tmp" >/dev/null
empty="$tmp/untracked"
mkdir -p "$empty"
scratch_repo_init "$empty"
printf 'The example account is 123456789012.\n' >"$empty/notes.md"
if "$guard" "$empty" >/dev/null 2>&1; then
  echo "account-artifact guard accepted a tree with nothing tracked" >&2
  exit 1
fi
echo "account-artifact guard mutation test: ok"
