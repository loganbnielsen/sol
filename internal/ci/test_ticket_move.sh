#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/scratch_repo.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/internal/ci/context/check_ticket_move.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
scratch_repo_init . -b main
git config user.email t@example.invalid
git config user.name test

T=internal/pipeline/tickets
mkdir -p "$T/READY_FOR_ENGINEERING" "$T/DONE" "$T/BACKLOG" app/payments/charge_svc

printf -- '---\nid: INFRA-900\n---\nready\n' > "$T/READY_FOR_ENGINEERING/INFRA-900.md"
printf -- '---\nid: INFRA-901\n---\nready\n' > "$T/READY_FOR_ENGINEERING/INFRA-901.md"
printf -- '---\nid: CODE_LAYER-900\n---\nready\n' > "$T/READY_FOR_ENGINEERING/CODE_LAYER-900.md"
printf -- '---\nid: INFRA-902\n---\nbacklog\n' > "$T/BACKLOG/INFRA-902.md"
printf -- '---\nid: INFRA-903\n---\ndone\n' > "$T/DONE/INFRA-903.md"
printf 'FROM scratch\n' > app/payments/charge_svc/Dockerfile
git add -A >/dev/null
git commit -qm "base"

run_check() { "$CHECK" --base main "$@" >/dev/null 2>&1; }

git checkout -q -b fix/infra-900-something
echo "code" > app/payments/charge_svc/main.ml
git add -A >/dev/null
git commit -qm "fix: do the thing (INFRA-900)"
if run_check --branch fix/infra-900-something; then
  echo "  [FAIL] a branch naming READY INFRA-900 passed without moving it" >&2
  exit 1
fi
echo "  [OK]   a named READY ticket left behind is refused"

msg="$("$CHECK" --base main --branch fix/infra-900-something 2>&1 || true)"
case "$msg" in
  *INFRA-900*) echo "  [OK]   the refusal names the ticket" ;;
  *) echo "  [FAIL] the refusal does not name the ticket: $msg" >&2; exit 1 ;;
esac

git mv "$T/READY_FOR_ENGINEERING/INFRA-900.md" "$T/DONE/INFRA-900.md"
git commit -qm "ticket: land INFRA-900"
if ! run_check --branch fix/infra-900-something; then
  echo "  [FAIL] a branch that lands its ticket was refused" >&2
  exit 1
fi
echo "  [OK]   landing the ticket satisfies the guard"

git checkout -q -b fix/code_layer-900-undo main
echo "code" > app/payments/charge_svc/underscore.ml
git add -A >/dev/null
git commit -qm "fix: do the underscore thing (CODE_LAYER-900)"
if run_check --branch fix/code_layer-900-undo; then
  echo "  [FAIL] an underscore ticket id (CODE_LAYER-900) left behind was not refused" >&2
  exit 1
fi
echo "  [OK]   an underscore ticket id is recognised and refused when left behind"

git mv "$T/READY_FOR_ENGINEERING/CODE_LAYER-900.md" "$T/DONE/CODE_LAYER-900.md"
git commit -qm "ticket: land CODE_LAYER-900"
if ! run_check --branch fix/code_layer-900-undo; then
  echo "  [FAIL] a branch that lands its underscore ticket was refused" >&2
  exit 1
fi
echo "  [OK]   landing the underscore ticket satisfies the guard"
git checkout -q main

git checkout -q -b chore/format-cleanup main
echo "x" > notes.txt
git add -A >/dev/null
git commit -qm "chore: tidy"
if ! run_check --branch chore/format-cleanup; then
  echo "  [FAIL] a branch naming no ticket was refused" >&2
  exit 1
fi
echo "  [OK]   a branch naming no ticket passes"

if ! run_check --branch docs/fnd-0024-fixed; then
  echo "  [FAIL] a finding-only branch was refused" >&2
  exit 1
fi
echo "  [OK]   a finding-only branch passes"

git checkout -q -b fix/infra-902-not-ready main
if ! run_check --branch fix/infra-902-not-ready; then
  echo "  [FAIL] a BACKLOG ticket's branch was refused" >&2
  exit 1
fi
echo "  [OK]   a ticket that is not READY at the base passes"

if ! run_check --branch fix/infra-903-already-done; then
  echo "  [FAIL] an already-DONE ticket's branch was refused" >&2
  exit 1
fi
echo "  [OK]   an already-DONE ticket passes"

git checkout -q -b fix/infra-901a-part-one main
echo "code" > app/payments/charge_svc/part.ml
git add -A >/dev/null
git commit -qm "fix: first half (INFRA-901, part A)"
if ! run_check --branch fix/infra-901a-part-one; then
  echo "  [FAIL] a declared partial was refused" >&2
  exit 1
fi
echo "  [OK]   '(INFRA-901, part A)' is accepted"

git checkout -q -b fix/infra-901b-unmarked main
echo "code" > app/payments/charge_svc/part2.ml
git add -A >/dev/null
git commit -qm "fix: second half (INFRA-901)"
if run_check --branch fix/infra-901b-unmarked; then
  echo "  [FAIL] the partial marker leaked to an unmarked branch" >&2
  exit 1
fi
echo "  [OK]   an unmarked branch for the same ticket is still refused"

git checkout -q main
if ! run_check --branch main; then
  echo "  [FAIL] main was refused" >&2
  exit 1
fi
echo "  [OK]   main passes"


git clone -q --depth 1 "file://$tmp" "$tmp/shallow"
cd "$tmp/shallow"
git fetch -q --depth 1 origin fix/infra-901a-part-one
git checkout -q FETCH_HEAD
if "$CHECK" --base origin/main --branch fix/infra-901a-part-one >/dev/null 2>&1; then
  echo "  [FAIL] a shallow checkout was judged instead of refused" >&2
  exit 1
fi
shallow_out="$("$CHECK" --base origin/main --branch fix/infra-901a-part-one 2>&1 || true)"
case "$shallow_out" in
  *shallow*) ;;
  *)
    echo "  [FAIL] the shallow refusal did not name the cause" >&2
    printf '%s\n' "$shallow_out" >&2
    exit 1
    ;;
esac
echo "  [OK]   a shallow checkout is refused, naming the cause"
cd "$tmp"

echo "ticket-move guard: all expectations hold."
