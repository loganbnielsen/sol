#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/devtools/ci/check_ticket_transitions.sh"

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

pass "create ready ticket on a branch" 'A\tpipeline/tickets/READY_FOR_ENGINEERING/AUDIT-999.md\n'
pass "create backlog ticket on a branch" 'A\tpipeline/tickets/BACKLOG/DEC-999.md\n'
pass "edit ready ticket" 'M\tpipeline/tickets/READY_FOR_ENGINEERING/AUDIT-999.md\n'
pass "edit done ticket in a corrective PR" 'M\tpipeline/tickets/DONE/AUDIT-999.md\n'
pass "promote backlog to ready" 'R100\tpipeline/tickets/BACKLOG/AUDIT-999.md\tpipeline/tickets/READY_FOR_ENGINEERING/AUDIT-999.md\n'
pass "complete ready ticket" 'R100\tpipeline/tickets/READY_FOR_ENGINEERING/AUDIT-999.md\tpipeline/tickets/DONE/AUDIT-999.md\n'
pass "reopen reverted ticket" 'D\tpipeline/tickets/DONE/AUDIT-999.md\nA\tpipeline/tickets/READY_FOR_ENGINEERING/AUDIT-999.md\n'

fail "reject direct DONE creation" 'A\tpipeline/tickets/DONE/AUDIT-999.md\n'
fail "reject deletion without transition" 'D\tpipeline/tickets/READY_FOR_ENGINEERING/AUDIT-999.md\n'
fail "reject changed ticket id" 'R100\tpipeline/tickets/READY_FOR_ENGINEERING/AUDIT-999.md\tpipeline/tickets/DONE/AUDIT-998.md\n'
fail "reject backlog to done jump" 'R100\tpipeline/tickets/BACKLOG/AUDIT-999.md\tpipeline/tickets/DONE/AUDIT-999.md\n'

echo "ticket-transition guard: all expectations hold."
