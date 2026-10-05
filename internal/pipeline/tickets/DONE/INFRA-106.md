---
id: INFRA-106
type: infra
severity: high
source: alpha.7 GCP attempt 5, 2026-10-04
title: Keep qualification teardown active when its stdout consumer disappears
---

**Depends on:** None.

## Premise verified

Re-verified 2026-10-04 on `f05e6259`. `internal/qualification/gcp/live-qual.sh` wrote every
progress line through the caller's stdout and installed only an `EXIT` trap. Writing to a closed
pipe raised `SIGPIPE`, whose default action terminated the shell; when the death landed inside
the `EXIT` trap at the first `say` of `cleanup`, `destroy` never ran, which is why attempt 5's
GKE cluster and Cloud SQL instance survived the failed platform apply. A minimal reproduction
(a `set -euo pipefail` script whose `EXIT` trap writes to a pipe whose reader has exited) shows
the trap body dying on its first `printf` and the teardown never executing.
`internal/qualification/aws/live-row.sh` had no teardown trap at all and died the same way.

## Remediation

Both harnesses ignore `SIGPIPE` and write their narrative to their own log first, mirroring to
the caller's stdout only best-effort, so a lost reader cannot end the shell and the teardown that
follows. Each harness traps `TERM`/`INT` and exits through the same `EXIT` teardown path; the
trap names no child and issues no `kill`, so bash defers it until the in-flight foreground step
(including any Terraform the durable-root reconcile or `sol cloud apply` started) has returned,
and teardown then runs and verifies absence. GCP `stop` no longer signals a whole process group:
it SIGTERMs the run's recorded pid, lets the run's own trap tear down normally, and independently
verifies absence before falling back to the destroy path. AWS `phase_destroy` always runs the
independent inventory even when `sol cloud destroy` exits non-zero.

## Acceptance criteria

- Close the harness stdout reader during a fixture run; the harness still tears down and records
  its verdict.
- Exercise `SIGPIPE` and `SIGTERM` without silently abandoning billable resources or corrupting
  Terraform state.
- Example impact: none; qualification machinery only. Language-parity impact: none.

## Checks

- `internal/qualification/gcp/test-live-qual.sh` — 277 passed. New scenarios: "the harness
  survives a closed stdout reader and still tears down (attempt-5 shape)" and "SIGTERM tears
  down and verifies absence without killing Terraform in flight"; the process-discipline checks
  now assert the run is signalled by pid, no group kill remains, and `on_terminate` contains no
  `kill`.
- `internal/qualification/aws/test-live-row.sh` — 75 passed. New scenarios: "the destroy phase
  survives a closed stdout reader and records the inventory" and "SIGTERM during cloud tears
  down and records the independent inventory".
- Mutation checks: removing `trap '' PIPE` makes the closed-reader scenario fail in each suite
  (5 assertions in GCP, 4 in AWS); restoring it returns both suites green. This is the exact
  attempt-5 failure, so the fixtures are demonstrated capable of failing.
- `internal/ci/check_no_comments.sh`, `internal/ci/check_durable_dns_zone.py`,
  `internal/ci/check_public_cloud_lifecycle.sh`, `internal/qualification/gcp/test-verify-matrix.sh`
  and `python3 internal/qualification/gcp/test_observer.py` all pass.

## Completion notes

The teardown path is now independent of the caller's stdout and of whether the harness is killed
politely: a closed reader or a `SIGTERM` leaves the harness running its teardown and the
independent inventory. The harness never signals Terraform, so an in-flight provider operation
is allowed to finish before teardown; the recorded process-group file is retained as evidence but
is no longer used to signal. Example impact: none; qualification machinery only, no demo/reference
application change. Language-parity impact: none; both harnesses share the mechanism and the
provider streams are language-neutral.
