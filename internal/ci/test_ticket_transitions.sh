#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/internal/ci/context/check_ticket_transitions.sh"

pass() {
  printf '%b' "$2" | "$CHECK" >/dev/null
  echo "  [OK]   $1"
}

fail() {
  if printf '%b' "$2" | "$CHECK" >/dev/null 2>&1; then
    echo "  [FAIL] $1"
    exit 1
  fi
  echo "  [OK]   $1"
}

fail_saying() {
  local output
  if output="$(printf '%b' "$2" | "$CHECK" 2>&1)"; then
    echo "  [FAIL] $1 (guard passed)"
    exit 1
  fi
  case "$output" in
    *"$3"*) echo "  [OK]   $1" ;;
    *)
      echo "  [FAIL] $1 (refusal did not explain the fix)"
      printf '%s\n' "$output"
      exit 1
      ;;
  esac
}

pass "create ready ticket on a branch" 'A\tinternal/pipeline/tickets/READY_FOR_ENGINEERING/AUDIT-999.md\n'
pass "create backlog ticket on a branch" 'A\tinternal/pipeline/tickets/BACKLOG/DEC-999.md\n'
pass "edit ready ticket" 'M\tinternal/pipeline/tickets/READY_FOR_ENGINEERING/AUDIT-999.md\n'
pass "edit done ticket in a corrective PR" 'M\tinternal/pipeline/tickets/DONE/AUDIT-999.md\n'
pass "promote backlog to ready" 'R100\tinternal/pipeline/tickets/BACKLOG/AUDIT-999.md\tinternal/pipeline/tickets/READY_FOR_ENGINEERING/AUDIT-999.md\n'
pass "complete ready ticket" 'R100\tinternal/pipeline/tickets/READY_FOR_ENGINEERING/AUDIT-999.md\tinternal/pipeline/tickets/DONE/AUDIT-999.md\n'
pass "reopen reverted ticket" 'D\tinternal/pipeline/tickets/DONE/AUDIT-999.md\nA\tinternal/pipeline/tickets/READY_FOR_ENGINEERING/AUDIT-999.md\n'
pass "move the ticket root" 'R100\tpipeline/tickets/DONE/AUDIT-999.md\tinternal/pipeline/tickets/DONE/AUDIT-999.md\n'

fail_saying "reject direct DONE creation" 'A\tinternal/pipeline/tickets/DONE/AUDIT-999.md\n' "file it in BACKLOG or READY_FOR_ENGINEERING in its own PR first"
fail "reject deletion without transition" 'D\tinternal/pipeline/tickets/READY_FOR_ENGINEERING/AUDIT-999.md\n'
fail "reject changed ticket id" 'R100\tinternal/pipeline/tickets/READY_FOR_ENGINEERING/AUDIT-999.md\tinternal/pipeline/tickets/DONE/AUDIT-998.md\n'
pass "complete a backlog ticket in one go" 'R100\tinternal/pipeline/tickets/BACKLOG/AUDIT-999.md\tinternal/pipeline/tickets/DONE/AUDIT-999.md\n'

echo "ticket-transition guard: all expectations hold."
