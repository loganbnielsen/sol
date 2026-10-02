#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/scratch_repo.sh"

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
scratch_repo_init "$scratch" -b main
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

mkdir -p "$linked/internal/ci"
cp "$root/internal/tooling/hooks/pre-push" "$linked/internal/tooling/hooks/pre-push"
cat >"$linked/internal/ci/run_fast_checks.sh" <<'RUNNER'
#!/usr/bin/env bash
cd "$(dirname "$0")/../.."
for name in $(git rev-parse --local-env-vars); do
  [ -z "${!name+set}" ] || echo "leaked $name"
done >runner-report
echo "toplevel $(git rev-parse --show-toplevel)" >>runner-report
echo "branch $(git rev-parse --abbrev-ref HEAD)" >>runner-report
RUNNER
printf 'runner-report\n' >>"$linked/.gitignore"
git_test -C "$linked" add -A
git_test -C "$linked" commit -q -m "pre-push under test"
scratch_repo_init "$tmp/remote.git" --bare
git -C "$linked" push -q "$tmp/remote.git" linked \
  || fail "git push through the tracked pre-push hook failed"
[ -e "$linked/runner-report" ] || fail "git push did not run the pre-push runner"
! grep -q '^leaked ' "$linked/runner-report" \
  || fail "the pre-push runner inherited git's repository-local variables: $(grep '^leaked ' "$linked/runner-report")"
grep -qx "toplevel $(cd "$linked" && pwd -P)" "$linked/runner-report" \
  || fail "a nested git call under git push resolved the wrong worktree: $(grep '^toplevel ' "$linked/runner-report")"
grep -qx "branch linked" "$linked/runner-report" \
  || fail "a nested git call under git push saw the wrong branch: $(grep '^branch ' "$linked/runner-report")"
pass "under a real git push, nested git calls in the runner see the pushing worktree"

echo ""
echo "hook install: all expectations hold."
