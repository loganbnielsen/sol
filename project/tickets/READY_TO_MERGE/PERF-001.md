---
id: PERF-001
type: performance
severity: high
source: cross-cutting-design-review 2026-08-31
branch: PERF-001/slow-test-infra-visibility
worktree: /home/lbendtly/Code/sol-PERF-001-slow-test-infra-visibility
pr: https://github.com/loganbnielsen/sol/pull/154
---

Make slow tests and stale local infra visible by default

**Depends on:** REFAC-066.

## Problem

The repo has per-suite timeouts and timing baselines, but local Docker/k3d
state can sit around for days and distort infra-dependent test behavior. A
service shutdown bug also looked like a slow test until the test process was
timed with a hard kill.

## Goal

Keep the existing test runner simple, but make stale infra and slow suites easy
to reset and diagnose.

## Acceptance criteria

- `run_tests.sh --reset-infra` removes only Sun-owned local containers and the
  `sun-local` k3d cluster before recreating requested infra.
- Timeout handling cannot be bypassed by application SIGTERM handlers when used
  for profiling/checking hangs.
- The runner reports per-suite duration and regression status as it does today.
- Add finer profiling only after a repeat offender needs per-test timing.

## Review — automated checks passed
Build clean; diff scoped to run_tests.sh (reset_infra container list) + expected perf_baseline.json append; grafana/tempo now match all 7 ensure-*.sh container names exactly plus sol-registry; independently verified the other two acceptance criteria (timeout -s KILL at run_tests.sh:189, duration/regression reporting via baseline_get/append/is_regression) already hold in current source, not just implementer's claim.
