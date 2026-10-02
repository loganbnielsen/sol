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

git_test() {
  git -c user.email=test@example.com -c user.name=test -c commit.gpgsign=false "$@"
}

scratch="$tmp/repo"
mkdir -p "$scratch/internal/tooling/scripts" "$scratch/internal/tooling/hooks"
cp "$root/internal/tooling/scripts/install-hooks.sh" "$scratch/internal/tooling/scripts/"
cat >"$scratch/internal/tooling/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
touch "$(git rev-parse --show-toplevel)/hook-ran"
HOOK
git init -q -b main "$scratch"
printf 'hook-ran\n' >"$scratch/.gitignore"

ln -sf "$tmp/devtools/hooks/pre-commit" "$scratch/.git/hooks/pre-commit"

(cd "$scratch" && bash internal/tooling/scripts/install-hooks.sh >/dev/null) \
  || fail "install-hooks.sh failed in a scratch repository"

[ "$(git -C "$scratch" config core.hooksPath)" = "internal/tooling/hooks" ] \
  || fail "core.hooksPath is not internal/tooling/hooks after install"
pass "the installer points core.hooksPath at the tracked hooks"

[ -x "$scratch/internal/tooling/hooks/pre-commit" ] \
  || fail "the installer did not make the hook sources executable"
pass "hook sources are executable"

git_test -C "$scratch" add -A
git_test -C "$scratch" commit -q -m init
[ -e "$scratch/hook-ran" ] || fail "a commit in the main checkout did not run the tracked hook"
pass "a commit runs the tracked hook, past a dangling .git/hooks symlink"

(cd "$scratch" && bash internal/tooling/scripts/install-hooks.sh >/dev/null) \
  || fail "re-running install-hooks.sh failed"
pass "re-running the installer is safe"

linked="$tmp/linked"
git -C "$scratch" worktree add -q -b linked "$linked"
cat >"$linked/internal/tooling/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
touch "$(git rev-parse --show-toplevel)/linked-hook-ran"
HOOK
printf 'linked-hook-ran\n' >>"$linked/.gitignore"
git_test -C "$linked" add -A
git_test -C "$linked" commit -q -m linked
[ -e "$linked/linked-hook-ran" ] \
  || fail "a commit in a linked worktree did not run that worktree's own hook"
pass "a linked worktree runs its own checkout's hooks with no install of its own"

echo ""
echo "hook install: all expectations hold."
