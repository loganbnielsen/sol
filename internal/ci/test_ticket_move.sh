#!/usr/bin/env bash
# Mutation test for internal/ci/check_ticket_move.sh (INFRA-066).
#
# The guard's whole value is the refusal, so both directions are asserted: a branch
# that names a READY ticket and leaves it behind must fail, and every legitimate
# shape that must not be blocked — a branch naming no ticket, a ticket that is not
# READY at the base, an already-DONE ticket, and a declared partial — must pass.
# A guard that cannot fail is decorative; one that fires on ordinary branches gets
# switched off.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/internal/ci/check_ticket_move.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
git init -q -b main .
git config user.email t@example.invalid
git config user.name test

T=internal/pipeline/tickets
mkdir -p "$T/READY_FOR_ENGINEERING" "$T/DONE" "$T/BACKLOG" app/payments/charge_svc

# Base state: two tickets ready for engineering, one that is not ready, one already
# done, and a finding (which is not a ticket and must never be demanded).
printf -- '---\nid: INFRA-900\n---\nready\n' > "$T/READY_FOR_ENGINEERING/INFRA-900.md"
printf -- '---\nid: INFRA-901\n---\nready\n' > "$T/READY_FOR_ENGINEERING/INFRA-901.md"
printf -- '---\nid: INFRA-902\n---\nbacklog\n' > "$T/BACKLOG/INFRA-902.md"
printf -- '---\nid: INFRA-903\n---\ndone\n' > "$T/DONE/INFRA-903.md"
printf 'FROM scratch\n' > app/payments/charge_svc/Dockerfile
git add -A >/dev/null
git commit -qm "base"

run_check() { "$CHECK" --base main "$@" >/dev/null 2>&1; }

# ── must fail: a named READY ticket is left behind ───────────────────────────
git checkout -q -b fix/infra-900-something
echo "code" > app/payments/charge_svc/main.ml
git add -A >/dev/null
git commit -qm "fix: do the thing (INFRA-900)"
if run_check --branch fix/infra-900-something; then
  echo "  [FAIL] a branch naming READY INFRA-900 passed without moving it" >&2
  exit 1
fi
echo "  [OK]   a named READY ticket left behind is refused"

# The refusal must name the ticket and the fix, or it is not actionable.
msg="$("$CHECK" --base main --branch fix/infra-900-something 2>&1 || true)"
case "$msg" in
  *INFRA-900*) echo "  [OK]   the refusal names the ticket" ;;
  *) echo "  [FAIL] the refusal does not name the ticket: $msg" >&2; exit 1 ;;
esac

# ── must pass: the same branch once the ticket is landed ─────────────────────
git mv "$T/READY_FOR_ENGINEERING/INFRA-900.md" "$T/DONE/INFRA-900.md"
git commit -qm "ticket: land INFRA-900"
if ! run_check --branch fix/infra-900-something; then
  echo "  [FAIL] a branch that lands its ticket was refused" >&2
  exit 1
fi
echo "  [OK]   landing the ticket satisfies the guard"

# ── must pass: a branch that names no ticket ─────────────────────────────────
git checkout -q -b chore/format-cleanup main
echo "x" > notes.txt
git add -A >/dev/null
git commit -qm "chore: tidy"
if ! run_check --branch chore/format-cleanup; then
  echo "  [FAIL] a branch naming no ticket was refused" >&2
  exit 1
fi
echo "  [OK]   a branch naming no ticket passes"

# A finding id is not a ticket file, so a finding-only branch must pass.
if ! run_check --branch docs/fnd-0024-fixed; then
  echo "  [FAIL] a finding-only branch was refused" >&2
  exit 1
fi
echo "  [OK]   a finding-only branch passes"

# ── must pass: a ticket that is not READY at the base ────────────────────────
git checkout -q -b fix/infra-902-not-ready main
if ! run_check --branch fix/infra-902-not-ready; then
  echo "  [FAIL] a BACKLOG ticket's branch was refused" >&2
  exit 1
fi
echo "  [OK]   a ticket that is not READY at the base passes"

# ── must pass: a ticket already DONE at the base ─────────────────────────────
if ! run_check --branch fix/infra-903-already-done; then
  echo "  [FAIL] an already-DONE ticket's branch was refused" >&2
  exit 1
fi
echo "  [OK]   an already-DONE ticket passes"

# ── must pass: a declared partial (the multi-part convention) ───────────────
git checkout -q -b fix/infra-901a-part-one main
echo "code" > app/payments/charge_svc/part.ml
git add -A >/dev/null
git commit -qm "fix: first half (INFRA-901, part A)"
if ! run_check --branch fix/infra-901a-part-one; then
  echo "  [FAIL] a declared partial was refused" >&2
  exit 1
fi
echo "  [OK]   '(INFRA-901, part A)' is accepted"

# ...and the marker must not leak: the same branch without the marker still fails.
git checkout -q -b fix/infra-901b-unmarked main
echo "code" > app/payments/charge_svc/part2.ml
git add -A >/dev/null
git commit -qm "fix: second half (INFRA-901)"
if run_check --branch fix/infra-901b-unmarked; then
  echo "  [FAIL] the partial marker leaked to an unmarked branch" >&2
  exit 1
fi
echo "  [OK]   an unmarked branch for the same ticket is still refused"

# ── must pass: nothing to compare (already at the base) ─────────────────────
git checkout -q main
if ! run_check --branch main; then
  echo "  [FAIL] main was refused" >&2
  exit 1
fi
echo "  [OK]   main passes"

echo "ticket-move guard: all expectations hold."
