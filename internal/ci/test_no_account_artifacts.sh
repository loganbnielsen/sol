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

# A real-looking account id must fail, even in a plain markdown file.
printf 'AWS account: 987654321098\n' >>"$tmp/notes.md"
git -C "$tmp" add -A
if "$guard" "$tmp" >/dev/null 2>&1; then
  echo "guard accepted a real-looking account id in a tracked markdown file" >&2
  exit 1
fi

echo "account-artifact guard mutation test: ok"
