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
Testing `sol_jobs_pg'.
This run has ID `OC851A3A'.

  [OK]          claim by kind (BUG-044 a)                       0   two Make ...
  [OK]          claim by kind (BUG-044 a)                       1   another w...
  [OK]          claim by kind (BUG-044 a)                       2   a poller ...
  [OK]          claim by kind (BUG-044 a)                       3   enqueue r...
  [OK]          database failures are loud (BUG-044 c)          0   missing t...

Full test results in `/home/runner/work/sol/sol/_build/default/framework/ocaml/sol-jobs/test/_build/_tests/sol_jobs_pg'.
Test Successful in 4.675s. 20 tests run.
LOG

executed_outbox="$scratch/integration-outbox.log"
cat >"$executed_outbox" <<'LOG'
Testing `sol_outbox'.
This run has ID `HG5R9ITK'.

  [OK]          composition                                      0   the outbox and sol-jobs share one tr...
  [OK]          relay                                            1   a failed publish does not advance th...

Full test results in `/home/runner/work/sol/sol/_build/default/framework/ocaml/sol-outbox/test/_build/_tests/sol_outbox'.
Test Successful in 0.989s. 7 tests run.
LOG

cached_jobs="$scratch/cached-jobs.log"
: >"$cached_jobs"

cached_outbox="$scratch/cached-outbox.log"
: >"$cached_outbox"

no_cases="$scratch/integration-outbox-no-cases.log"
cat >"$no_cases" <<'LOG'
Testing `sol_outbox'.
This run has ID `HG5R9ITK'.

Full test results in `/home/logan/Code/sol-cloud/sol/_build/default/framework/ocaml/sol-outbox/test/_build/_tests/sol_outbox'.
Test Successful in 0.002s. 7 tests run.
LOG

if bash "$guard" "$executed_jobs" "$executed_outbox" >/dev/null 2>&1; then
  report 1 "CI-shaped logs showing the database groups pass"
else
  report 0 "CI-shaped logs showing the database groups pass"
fi

if bash "$guard" "$cached_jobs" "$executed_outbox" >/dev/null 2>&1; then
  report 0 "a cached run (no output at all) is refused"
else
  report 1 "a cached run (no output at all) is refused"
fi

if bash "$guard" "$no_cases" >/dev/null 2>&1; then
  report 0 "a suite run that never reached its database group is refused"
else
  report 1 "a suite run that never reached its database group is refused"
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
