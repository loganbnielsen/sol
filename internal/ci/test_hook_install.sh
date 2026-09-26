#!/usr/bin/env bash
# Pins the hook install path (REFAC-090).
#
# Why this exists: the local gate can be silently inert. In the session that
# produced REFAC-090, `.git/hooks/pre-commit` was a symlink to
# `<repo>/devtools/hooks/pre-commit`, a path that no longer existed, so an
# entirely ungated commit landed on another engineer's branch. Nothing in the
# repository noticed, and no test exercised the installer.
#
# This runs the documented installer in a *scratch* repository laid out the same
# way as this one, seeds exactly that dangling-symlink failure, and asserts the
# installer repairs it and leaves every hook source installed, resolving and
# executable. It fails if the hooks directory is moved without the installer
# following, because the installer's own chmod/link step then fails.
#
# It never touches this repository's .git/hooks.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { echo "  [OK]   $1"; }
fail() {
  echo "  [FAIL] $1" >&2
  exit 1
}

scratch="$tmp/repo"
mkdir -p "$scratch/internal/tooling/scripts" "$scratch/internal/tooling/hooks"
cp "$root/internal/tooling/scripts/install-hooks.sh" "$scratch/internal/tooling/scripts/"
cp "$root"/internal/tooling/hooks/* "$scratch/internal/tooling/hooks/"
chmod +x "$scratch"/internal/tooling/hooks/*
git init -q -b main "$scratch"

source_count="$(find "$scratch/internal/tooling/hooks" -maxdepth 1 -type f | wc -l | tr -d ' ')"
[ "$source_count" -gt 0 ] || fail "no hook sources found to install"

# The exact field failure: a hook left pointing at a path that no longer exists.
ln -sf "$tmp/devtools/hooks/pre-commit" "$scratch/.git/hooks/pre-commit"

(cd "$scratch" && bash internal/tooling/scripts/install-hooks.sh >/dev/null) \
  || fail "install-hooks.sh failed in a scratch repository"

installed=0
for src in "$scratch"/internal/tooling/hooks/*; do
  name="$(basename "$src")"
  dest="$scratch/.git/hooks/$name"

  [ -L "$dest" ] || fail "$name is not a symlink after install"
  [ -x "$dest" ] || fail "$name is not executable after install"

  resolved="$(readlink -f "$dest")"
  [ "$resolved" = "$(readlink -f "$src")" ] \
    || fail "$name resolves to '$resolved', not the hook source '$src'"
  installed=$((installed + 1))
  pass "$name installed, resolving and executable"
done

[ "$installed" -eq "$source_count" ] \
  || fail "installed $installed hooks but $source_count sources exist"

# The dangling symlink must be gone, not merely shadowed.
case "$(readlink -f "$scratch/.git/hooks/pre-commit")" in
  *devtools*) fail "the dangling install was not repaired" ;;
esac
pass "a pre-existing dangling hook symlink is repaired"

# Re-running is safe and must not leave anything worse behind.
(cd "$scratch" && bash internal/tooling/scripts/install-hooks.sh >/dev/null) \
  || fail "re-running install-hooks.sh failed"
readlink -f "$scratch/.git/hooks/pre-commit" >/dev/null \
  || fail "re-running install-hooks.sh left the pre-commit hook unresolvable"
pass "re-running the installer is safe"

echo ""
echo "hook install: all expectations hold."
