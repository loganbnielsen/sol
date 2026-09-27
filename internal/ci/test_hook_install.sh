#!/usr/bin/env bash
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

case "$(readlink -f "$scratch/.git/hooks/pre-commit")" in
  *devtools*) fail "the dangling install was not repaired" ;;
esac
pass "a pre-existing dangling hook symlink is repaired"

(cd "$scratch" && bash internal/tooling/scripts/install-hooks.sh >/dev/null) \
  || fail "re-running install-hooks.sh failed"
readlink -f "$scratch/.git/hooks/pre-commit" >/dev/null \
  || fail "re-running install-hooks.sh left the pre-commit hook unresolvable"
pass "re-running the installer is safe"

echo ""
echo "hook install: all expectations hold."
