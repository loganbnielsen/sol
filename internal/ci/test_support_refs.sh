#!/usr/bin/env bash
# Mutation test for check_support_refs.sh and bump-support-refs.sh (BUG-059).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/internal/ci/check_support_refs.sh"
BUMP="$ROOT/internal/tooling/scripts/bump-support-refs.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

mkrepo() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/.github/workflows" "$tmp/repo/cli"
  git -C "$tmp/repo" init -q
  printf '# refs\nfoo-eio https://github.com/loganbnielsen/foo-eio.git %s\nbar-eio https://github.com/loganbnielsen/bar-eio.git %s\n' "$A" "$B" \
    >"$tmp/repo/support-refs.txt"
  printf 'pin-depends: [\n  [ "foo-eio.0.1.0" "git+https://github.com/loganbnielsen/foo-eio.git#%s" ]\n]\n' "$A" \
    >"$tmp/repo/sol-x.opam"
  printf 'steps:\n  - run: bash internal/ci/pin-support-packages.sh support-refs.txt\n' \
    >"$tmp/repo/.github/workflows/ci.yml"
}

commit() {
  git -C "$tmp/repo" add -A
  git -C "$tmp/repo" -c user.email=t@t -c user.name=t commit -qm x
}

expect() {
  local want="$1" name="$2"
  if "$CHECK" "$tmp/repo" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" != "$want" ]; then
    echo "  [FAIL] $name (expected $want, got $got)"
    "$CHECK" "$tmp/repo" || true
    exit 1
  fi
  echo "  [OK]   $name"
}

mkrepo; commit
expect pass "declared refs, a consumer using the pin script, agreeing pin-depends"

mkrepo; printf 'RUN opam pin add foo-eio https://github.com/loganbnielsen/foo-eio.git#main -y\n' >"$tmp/repo/cli/x.ml"; commit
expect fail "a Dockerfile string pinning a support package at #main"

mkrepo; printf 'for p in foo-eio; do opam pin add -y "$p" "https://github.com/loganbnielsen/$p.git"; done\n' >"$tmp/repo/doc.md"; commit
expect fail "a loop pinning support repositories at their default branch"

mkrepo; printf 'sha=$(git ls-remote https://github.com/loganbnielsen/foo-eio.git refs/heads/main)\n' >"$tmp/repo/x.sh"; commit
expect fail "resolving a support package's branch at build time"

mkrepo; printf 'opam pin add bar-eio ./vendor/bar-eio -y\n' >"$tmp/repo/x.sh"; commit
expect fail "pinning a support package outside the pin script"

mkrepo; printf 'foo-eio https://github.com/loganbnielsen/foo-eio.git main\n' >>"$tmp/repo/support-refs.txt"; commit
expect fail "a declaration naming a branch instead of a commit"

mkrepo; sed -i "s/#$A/#$B/" "$tmp/repo/sol-x.opam"; commit
expect fail "pin-depends disagreeing with support-refs.txt"

mkrepo; printf 'see https://github.com/loganbnielsen/foo-eio.git#%s\n' "$A" >"$tmp/repo/doc.md"; commit
expect pass "a reference at an exact commit"

# bump: moves the declaration and the matching pin-depends together.
mkrepo
for n in foo-eio bar-eio; do
  git init -q -b main "$tmp/src-$n"
  git -C "$tmp/src-$n" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$n"
done
new_foo="$(git -C "$tmp/src-foo-eio" rev-parse HEAD)"
sed -i "s|https://github.com/loganbnielsen/foo-eio.git|file://$tmp/src-foo-eio|; s|https://github.com/loganbnielsen/bar-eio.git|file://$tmp/src-bar-eio|" "$tmp/repo/support-refs.txt"
sed -i "s|https://github.com/loganbnielsen/foo-eio.git#$A|https://github.com/loganbnielsen/foo-eio.git#$A|" "$tmp/repo/sol-x.opam"
commit
SUPPORT_ROOT="$tmp/repo" "$BUMP" foo-eio >/dev/null
grep -q "file://$tmp/src-foo-eio $new_foo" "$tmp/repo/support-refs.txt" || { echo "  [FAIL] bump did not move foo-eio"; exit 1; }
grep -q "bar-eio file://$tmp/src-bar-eio $B" "$tmp/repo/support-refs.txt" || { echo "  [FAIL] bump moved a package it was not asked to"; exit 1; }
grep -q "foo-eio.git#$new_foo" "$tmp/repo/sol-x.opam" || { echo "  [FAIL] bump left pin-depends behind"; exit 1; }
echo "  [OK]   bump moves the named package and its pin-depends, and nothing else"

# pin: every declared package, in order, at exactly its commit; a malformed
# declaration pins nothing further.
mkdir -p "$tmp/bin"
printf '#!/bin/sh\necho "$*" >>"%s/opam.log"\n' "$tmp" >"$tmp/bin/opam"
chmod +x "$tmp/bin/opam"
mkrepo
PATH="$tmp/bin:$PATH" bash "$ROOT/internal/ci/pin-support-packages.sh" "$tmp/repo/support-refs.txt" >/dev/null
want="$(printf 'pin add foo-eio https://github.com/loganbnielsen/foo-eio.git#%s -y\npin add bar-eio https://github.com/loganbnielsen/bar-eio.git#%s -y' "$A" "$B")"
[ "$(cat "$tmp/opam.log")" = "$want" ] || { echo "  [FAIL] pin script pinned:"; cat "$tmp/opam.log"; exit 1; }
echo "  [OK]   pin script pins each declared package, in order, at its commit"
rm -f "$tmp/opam.log"
printf 'baz-eio https://github.com/loganbnielsen/baz-eio.git main\n' >>"$tmp/repo/support-refs.txt"
if PATH="$tmp/bin:$PATH" bash "$ROOT/internal/ci/pin-support-packages.sh" "$tmp/repo/support-refs.txt" >/dev/null 2>&1; then
  echo "  [FAIL] pin script accepted a branch"; exit 1
fi
grep -q baz-eio "$tmp/opam.log" && { echo "  [FAIL] pin script pinned a branch"; exit 1; }
echo "  [OK]   pin script refuses a declaration that is not a commit"
