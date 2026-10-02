#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/scratch_repo.sh"

root="$(git rev-parse --show-toplevel)"
check="$root/internal/ci/check_authority.sh"
hook="$root/internal/tooling/hooks/pre-commit"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { echo "  [OK]   $1"; }
fail() {
  echo "  [FAIL] $1" >&2
  exit 1
}

mkrepo() {
  local dir="$1"
  scratch_repo_init "$dir" -b main
  git -C "$dir" config user.email test@example.test
  git -C "$dir" config user.name test
  echo one >"$dir/f"
  git -C "$dir" add f
  git -C "$dir" commit -qm "one"
}

run_check() {
  local dir="$1"
  shift
  (cd "$dir" && env "$@" bash "$check")
}

repo="$tmp/plain"
mkrepo "$repo"

out="$(run_check "$repo")" || fail "a clean branch with no declaration should not be refused"
case "$out" in
  *"canonical checkout"*)
    fail "a single-worktree repository must not warn about the canonical checkout"
    ;;
esac
pass "no declaration, single worktree: advisory and quiet"

if run_check "$repo" "SOL_AUTHORITY_WORKTREE=$tmp/somewhere-else" >/dev/null 2>&1; then
  fail "a declared worktree that is not this one must be refused"
fi
pass "declared worktree mismatch is refused"

if run_check "$repo" "SOL_AUTHORITY_BRANCH=not-this-branch" >/dev/null 2>&1; then
  fail "a declared branch that is not this one must be refused"
fi
pass "declared branch mismatch is refused"

git -C "$repo" checkout -q --orphan unrelated
git -C "$repo" commit -qm "unrelated root"
other="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q main
if run_check "$repo" "SOL_AUTHORITY_BASE=$other" >/dev/null 2>&1; then
  fail "a declared base that is not an ancestor of HEAD must be refused"
fi
pass "declared base that is not an ancestor is refused"

head_sha="$(git -C "$repo" rev-parse HEAD)"
run_check "$repo" \
  "SOL_AUTHORITY_WORKTREE=$repo" \
  "SOL_AUTHORITY_BRANCH=main" \
  "SOL_AUTHORITY_BASE=$head_sha" >/dev/null \
  || fail "a correct declaration must be accepted"
pass "a correct declaration is accepted"

git -C "$repo" checkout -q -b feature-no-upstream
run_check "$repo" >/dev/null || fail "a branch with no upstream must not be refused"
pass "a branch with no upstream is not refused"

echo two >"$repo/f"
git -C "$repo" add f
git -C "$repo" checkout -q --detach
git -C "$repo" add f
out="$(run_check "$repo")" || fail "a detached HEAD with staged changes must not be refused"
case "$out" in
  *detached*) : ;;
  *) fail "a detached HEAD with staged changes should warn" ;;
esac
pass "detached HEAD with staged changes warns but proceeds"

git -C "$repo" checkout -q main
git -C "$repo" worktree add -q --detach "$tmp/second" main >/dev/null 2>&1
out="$(run_check "$repo")"
case "$out" in
  *"canonical checkout"*) : ;;
  *) fail "committing from the canonical checkout while other worktrees exist should warn" ;;
esac
pass "canonical-checkout warning fires only when other worktrees exist"

hookrepo="$tmp/hookrepo"
mkrepo "$hookrepo"
mkdir -p "$hookrepo/internal/ci" "$hookrepo/internal/tooling/hooks"
cp "$check" "$hookrepo/internal/ci/check_authority.sh"
cp "$hook" "$hookrepo/internal/tooling/hooks/pre-commit"
chmod +x "$hookrepo/internal/tooling/hooks/pre-commit"

if (cd "$hookrepo" && SOL_AUTHORITY_BRANCH=not-this-branch \
      bash internal/tooling/hooks/pre-commit >/dev/null 2>&1); then
  fail "the hook must refuse a mismatched declared context"
fi
pass "the pre-commit hook refuses a mismatched declared context"

: >"$hookrepo/.git/MERGE_HEAD"
(cd "$hookrepo" && bash internal/tooling/hooks/pre-commit >/dev/null 2>&1) \
  || fail "a merge commit must not be blocked"
pass "a merge commit is not blocked"

echo ""
echo "authority preflight: all expectations hold."
