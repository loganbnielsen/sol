#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$repo_root/internal/ci/check_integration_suites_ran.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

pass=0
fail=0

report() {
  local ok="$1" label="$2"
  if [ "$ok" = "1" ]; then
    echo "  ok: $label"
    pass=$((pass + 1))
  else
    echo "  FAIL: $label"
    fail=$((fail + 1))
  fi
}

executed_jobs="$scratch/integration-jobs.log"
cat >"$executed_jobs" <<'LOG'
  [OK]          claim by kind (BUG-044 a)                       1   another workspace's rows are never claimed....
  [OK]          claim by kind (BUG-044 a)                       2   a poller sweeps only its own terminal rows....
Test Successful in 5.294s. 24 tests run.
LOG

executed_outbox="$scratch/integration-outbox.log"
cat >"$executed_outbox" <<'LOG'
  [OK]          composition                                      6   the outbox and sol-jobs share one transaction...
Test Successful in 1.053s. 7 tests run.
LOG

cached_jobs="$scratch/cached-jobs.log"
: >"$cached_jobs"

cached_outbox="$scratch/cached-outbox.log"
printf '[skip] POSTGRES_URL not set\n' >"$scratch/skipped-outbox.log"

if bash "$guard" "$executed_jobs" "$executed_outbox" >/dev/null 2>&1; then
  report 1 "a log showing the database cases passes"
else
  report 0 "a log showing the database cases passes"
fi

if bash "$guard" "$cached_jobs" "$executed_outbox" >/dev/null 2>&1; then
  report 0 "a cached run (no case output) is refused"
else
  report 1 "a cached run (no case output) is refused"
fi

if bash "$guard" "$executed_jobs" "$scratch/skipped-outbox.log" >/dev/null 2>&1; then
  report 0 "a log without an executed database case is refused"
else
  report 1 "a log without an executed database case is refused"
fi

if bash "$guard" "$cached_outbox" >/dev/null 2>&1; then
  report 0 "an empty outbox log is refused"
else
  report 1 "an empty outbox log is refused"
fi

if bash "$guard" >/dev/null 2>&1; then
  report 0 "no logs at all is refused"
else
  report 1 "no logs at all is refused"
fi

echo "test_integration_suites_ran_check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
