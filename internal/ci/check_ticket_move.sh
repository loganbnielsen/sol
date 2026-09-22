#!/usr/bin/env bash
# A branch that names a READY ticket must land it (INFRA-066).
#
#   check_ticket_move.sh [--base REF] [--branch NAME] [--extra-text TEXT]
#
# The signal is the name the worker already chooses. This repository writes the
# ticket id into it consistently, in several shapes:
#
#   INFRA-061/probe-tri-state            (<ID>/<slug>)
#   fix/infra-048-namespace-create       (type-prefixed, lowercase)
#   sol-INFRA-049-omit-authority         (the worktree directory)
#   fix: ... (INFRA-050)                 (the commit subject)
#
# So (name, diff) is checkable without guessing from comments or PR bodies. When the
# id a branch names is in READY_FOR_ENGINEERING at the base, the branch must have
# moved it to DONE by its head — or say so if it is deliberately one part of a longer
# ticket, via "(<ID>, part …)" in a subject or "Part of: <ID>" in --extra-text.
#
# Why this exists: INFRA-048 (#388), INFRA-050 (#390) and INFRA-057 (#397+#398) all
# landed their fix and left the ticket reading as actionable, because the ticket-file
# move is a manual final step that nothing checked. The cost is a wasted cycle for
# whoever picks the ticket up next, or duplicate work.
#
# A branch that names no ticket at all is not this check's business: `chore/...`,
# `docs/...` and finding-only branches (`docs/fnd-0024-0025-fixed`) pass, since
# `fnd-0024` is not a ticket file.
#
# Exit: 0 nothing to require (or satisfied), 1 a named READY ticket was left behind,
# 2 bad usage.
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

# A guard that cannot read the branch's commits must not conclude "no declaration".
# That is the fail-open this file exists to prevent, one level up: in a shallow
# checkout `git log "$BASE..HEAD"` yields nothing, so the documented "(<ID>, part A)"
# escape hatch looks absent when the branch actually carries it — the branch name
# still names the ticket (it is a plain string), and a legitimate partial PR is
# refused with advice that cannot be followed. CI's test job checks out shallow by
# default; the guard refuses and says how to fix it instead of guessing.
if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
  echo "✗ this checkout is shallow, so this branch's commit subjects cannot be read." >&2
  echo "  Deepen it first: git fetch --unshallow (or --deepen=<n> covering the branch)." >&2
  echo "  Refusing rather than reporting 'no declaration': a guard that cannot see the" >&2
  echo "  commits must not conclude that there were none." >&2
  exit 2
fi

SUBJECTS="$(git log --format=%s "$BASE..HEAD" 2>/dev/null || true)"

# Ticket ids, lowercased for comparison. `infra-057a` yields `infra-057`, which is
# what the multi-part branches rely on.
lower_id_tokens() { tr 'A-Z' 'a-z' | grep -oE '[a-z]+-[0-9]+' || true; }

CANDIDATES="$(
  {
    printf '%s\n%s\n%s\n' "$BRANCH" "$WORKTREE" "$EXTRA" | lower_id_tokens
    # Commit subjects name the ticket in parentheses: "(INFRA-050)".
    printf '%s\n' "$SUBJECTS" | tr 'A-Z' 'a-z' | grep -oE '\([a-z]+-[0-9]+' | tr -d '(' || true
  } | grep -v '^$' | sort -u
)"

if [ -z "$CANDIDATES" ]; then
  exit 0
fi

# The two roots the transition guard also knows about; a one-time root move must not
# hide a ticket from this check.
ROOTS="internal/pipeline/tickets pipeline/tickets"

status=0
for lower in $CANDIDATES; do
  upper="$(printf '%s' "$lower" | tr 'a-z' 'A-Z')"
  for root in $ROOTS; do
    if ! git cat-file -e "$BASE:$root/READY_FOR_ENGINEERING/$upper.md" 2>/dev/null; then
      continue
    fi
    if git cat-file -e "$BASE:$root/DONE/$upper.md" 2>/dev/null; then
      # Already DONE at the base: a branch naming it is touching something else.
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
