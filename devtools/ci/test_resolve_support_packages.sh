#!/usr/bin/env bash
# Tests for resolve-support-packages.sh: a complete snapshot resolves, and one
# unresolvable package fails it.

set -uo pipefail

RESOLVE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-support-packages.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

check() {
  if [ "$2" = "$3" ]; then echo "  [OK]   $1"; else echo "  [FAIL] $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES + 1)); fi
}

for name in foo bar; do
  git init -q -b main "$WORK/$name"
  git -C "$WORK/$name" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m "$name"
done
FOO="$(git -C "$WORK/foo" rev-parse HEAD)"
BAR="$(git -C "$WORK/bar" rev-parse HEAD)"

printf '# list\n\nfoo-eio file://%s\nbar-eio file://%s\n' "$WORK/foo" "$WORK/bar" > "$WORK/complete"
check "every package resolves, in list order" \
  "$(printf 'foo-eio %s\nbar-eio %s' "$FOO" "$BAR")" "$("$RESOLVE" "$WORK/complete" 2>/dev/null)"

printf 'foo-eio file://%s\nmissing-eio file://%s/missing\n' "$WORK/foo" "$WORK" > "$WORK/partial"
"$RESOLVE" "$WORK/partial" > /dev/null 2>&1
check "one unresolvable package fails the snapshot" 1 "$?"

[ "$FAILURES" -eq 0 ] && echo "resolve-support-packages: all checks passed" || exit 1
