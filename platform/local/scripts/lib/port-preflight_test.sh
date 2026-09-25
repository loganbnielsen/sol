#!/usr/bin/env bash
# Self-check for check_port_forward_conflict's port-matching logic.
# Not part of the normal ensure-*.sh run path -- run directly to verify.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/port-preflight.sh"

ps() {
  case "$PS_STUB" in
    none)    ;;
    match)   echo "  12345 kubectl port-forward -n monitoring svc/loki 3100:3100" ;;
    other)   echo "  12345 kubectl port-forward -n monitoring svc/tempo 3200:3200" ;;
  esac
}

fail=0

PS_STUB=none
if ! check_port_forward_conflict 3100 loki > /dev/null 2>&1; then
  echo "FAIL: expected no conflict when no port-forward is running"; fail=1
fi

PS_STUB=match
if check_port_forward_conflict 3100 loki > /dev/null 2>&1; then
  echo "FAIL: expected a conflict for a port-forward bound to the same port"; fail=1
fi

PS_STUB=other
if ! check_port_forward_conflict 3100 loki > /dev/null 2>&1; then
  echo "FAIL: expected no conflict for a port-forward bound to a different port"; fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "port-preflight_test: all checks passed"
else
  exit 1
fi
