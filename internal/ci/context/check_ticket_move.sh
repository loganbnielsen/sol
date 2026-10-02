#!/usr/bin/env bash
set -uo pipefail

BASE=origin/main
BRANCH=""
EXTRA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      BASE="$2"
      shift 2
      ;;
    --branch)
      BRANCH="$2"
      shift 2
      ;;
    --extra-text)
      EXTRA="$2"
      shift 2
      ;;
    *)
      echo "usage: $0 [--base REF] [--branch NAME] [--extra-text TEXT]" >&2
      exit 2
      ;;
  esac
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "check_ticket_move: not a git repository" >&2
  exit 2
}
cd "$ROOT" || exit 2

[ -n "$BRANCH" ] || BRANCH="$(git rev-parse --abbrev-ref HEAD)"
WORKTREE="$(basename "$ROOT")"

if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
  echo "✗ this checkout is shallow, so this branch's commit subjects cannot be read." >&2
  echo "  Deepen it first: git fetch --unshallow (or --deepen=<n> covering the branch)." >&2
  echo "  Refusing rather than reporting 'no declaration': a guard that cannot see the" >&2
  echo "  commits must not conclude that there were none." >&2
  exit 2
fi

SUBJECTS="$(git log --format=%s "$BASE..HEAD" 2>/dev/null || true)"

lower_id_tokens() { tr 'A-Z' 'a-z' | grep -oE '[a-z_]+-[0-9]+' || true; }

CANDIDATES="$(
  {
    printf '%s\n%s\n%s\n' "$BRANCH" "$WORKTREE" "$EXTRA" | lower_id_tokens
    printf '%s\n' "$SUBJECTS" | tr 'A-Z' 'a-z' | grep -oE '\([a-z_]+-[0-9]+' | tr -d '(' || true
  } | grep -v '^$' | sort -u
)"

if [ -z "$CANDIDATES" ]; then
  exit 0
fi

ROOTS="internal/pipeline/tickets pipeline/tickets"

status=0
for lower in $CANDIDATES; do
  upper="$(printf '%s' "$lower" | tr 'a-z' 'A-Z')"
  for root in $ROOTS; do
    if ! git cat-file -e "$BASE:$root/READY_FOR_ENGINEERING/$upper.md" 2>/dev/null; then
      continue
    fi
    if git cat-file -e "$BASE:$root/DONE/$upper.md" 2>/dev/null; then
      continue
    fi
    if git cat-file -e "HEAD:$root/DONE/$upper.md" 2>/dev/null; then
      printf '  ✓ %s moves %s to DONE\n' "$BRANCH" "$upper"
      continue
    fi
    if printf '%s\n' "$SUBJECTS" | grep -qiE "\(${upper}, *part |part of: *${upper}"; then
      printf '  ✓ %s declares itself part of %s\n' "$BRANCH" "$upper"
      continue
    fi
    echo "" >&2
    echo "✗ This branch names $upper, which is READY_FOR_ENGINEERING at $BASE," >&2
    echo "  but its head does not move $upper.md to DONE/ ($root)." >&2
    echo "" >&2
    echo "  Either land it — 'git mv $root/READY_FOR_ENGINEERING/$upper.md \\" >&2
    echo "    $root/DONE/$upper.md' in this branch's final commit — or, if this is" >&2
    echo "  deliberately one part of a longer ticket, put '($upper, part A)' in a" >&2
    echo "  commit subject, or 'Part of: $upper' in the PR body." >&2
    echo "  Leaving it behind is how $upper keeps reporting as actionable with its" >&2
    echo "  fix already merged (INFRA-066)." >&2
    status=1
  done
done

exit "$status"
