#!/usr/bin/env bash
# Resolve and verify the actor's context before a commit or push (REFAC-090).
#
# The repository cannot tell an agent from a human, and cannot verify an
# "expected base" that the actor never declared. So the behaviour splits:
#
#   * With a declared context (any of SOL_AUTHORITY_WORKTREE / _BRANCH / _BASE),
#     reality is compared against the declaration and a mismatch is REFUSED
#     (exit 1). This is the check that would have caught a commit made from the
#     canonical checkout while it happened to be on another engineer's branch.
#   * With no declaration, only signals that are unambiguous are reported as
#     warnings, and the exit stays 0. A warning is never a gate, because a human
#     legitimately commits from the canonical checkout.
#
# It never requires a branch to have an upstream, and never inspects merge state,
# so it cannot block a merge commit or a rebase.
#
# Usage:
#   internal/ci/check_authority.sh
#
# Declaring a context (one line, and the same variables work for a push):
#   SOL_AUTHORITY_WORKTREE=/abs/path \
#   SOL_AUTHORITY_BRANCH=REFAC-090/slug \
#   SOL_AUTHORITY_BASE=main \
#   git commit ...

set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  # Not in a worktree at all: nothing to verify, and nothing to refuse.
  exit 0
}

CANONICAL="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
WORKTREE_COUNT="$(git worktree list --porcelain 2>/dev/null | grep -c '^worktree ' || true)"
BRANCH="$(git symbolic-ref -q --short HEAD 2>/dev/null || true)"
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"

DETACHED=0
[ -z "$BRANCH" ] && DETACHED=1

STAGED=0
git diff --cached --quiet 2>/dev/null || STAGED=1

PROBLEMS=()
WARNINGS=()

DECLARED=0
[ -n "${SOL_AUTHORITY_WORKTREE:-}${SOL_AUTHORITY_BRANCH:-}${SOL_AUTHORITY_BASE:-}" ] && DECLARED=1

# ── Declared context: fail closed on any disagreement ─────────────────────────
if [ -n "${SOL_AUTHORITY_WORKTREE:-}" ]; then
  declared_wt="$(cd "$SOL_AUTHORITY_WORKTREE" 2>/dev/null && pwd || true)"
  if [ "$declared_wt" != "$ROOT" ]; then
    PROBLEMS+=("declared worktree '$SOL_AUTHORITY_WORKTREE' is not this worktree ($ROOT)")
  fi
fi

if [ -n "${SOL_AUTHORITY_BRANCH:-}" ]; then
  if [ "$SOL_AUTHORITY_BRANCH" != "$BRANCH" ]; then
    PROBLEMS+=("declared branch '$SOL_AUTHORITY_BRANCH' is not the current branch '${BRANCH:-<detached HEAD>}'")
  fi
fi

if [ -n "${SOL_AUTHORITY_BASE:-}" ]; then
  if ! git merge-base --is-ancestor "$SOL_AUTHORITY_BASE" HEAD 2>/dev/null; then
    PROBLEMS+=("declared base '$SOL_AUTHORITY_BASE' is not an ancestor of HEAD $(git rev-parse --short HEAD 2>/dev/null)")
  fi
fi

# ── No declaration: advisory on the two signals the incident actually produced ─
if [ "$DECLARED" = 0 ]; then
  # Committing from the canonical checkout is the human's prerogative — and the
  # only checkout in a plain clone. It is only a signal when *other* worktrees
  # exist, which is the situation concurrent actors create.
  if [ "$WORKTREE_COUNT" -gt 1 ] && [ -n "$CANONICAL" ] && [ "$ROOT" = "$CANONICAL" ]; then
    WARNINGS+=("committing from the canonical checkout ($ROOT) while other worktrees exist — concurrent actors should each own a worktree (CONTRIBUTING.md § Isolation and ownership)")
  fi

  if [ "$DETACHED" = 1 ] && [ "$STAGED" = 1 ]; then
    WARNINGS+=("HEAD is detached with staged changes; a commit here is reachable only by its hash")
  fi
fi

if [ ${#PROBLEMS[@]} -gt 0 ]; then
  echo ""
  echo "✗ Authority preflight refused this operation."
  for p in "${PROBLEMS[@]}"; do
    echo "      - $p"
  done
  echo ""
  echo "      worktree: $ROOT"
  echo "      branch:   ${BRANCH:-<detached HEAD>}"
  echo "      upstream: ${UPSTREAM:-<none>}"
  echo ""
  echo "      Correct the SOL_AUTHORITY_* declaration, or unset it for advisory-only."
  echo "      See CONTRIBUTING.md § Isolation and ownership."
  exit 1
fi

if [ ${#WARNINGS[@]} -gt 0 ]; then
  echo ""
  echo "  ⚠  Authority preflight:"
  for w in "${WARNINGS[@]}"; do
    echo "       $w"
  done
  echo ""
fi

exit 0
