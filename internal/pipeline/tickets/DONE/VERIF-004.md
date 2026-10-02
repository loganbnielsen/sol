---
id: VERIF-004
type: refactor
severity: high
title: Suite membership is declared three times, and the guard only reads one of them
source: internal/pipeline/audits/2026-10-01_verification_architecture_audit.md
premise: '! rg -q check_framework_ci_coverage .github/workflows/ci.yml'
---

Suite membership is declared three times, and the guard only reads one of them

**Depends on:** None.

**Premise re-verified (2026-10-01)** against `origin/main @ fd138b3a`: computed from the sources,
the unit-suite directory list appears in `.github/workflows/ci.yml` (line 227),
`internal/ci/run_fast_checks.sh` (lines 7-12) and `internal/tooling/scripts/run_tests.sh`
(lines 92-96), and `internal/ci/check_framework_ci_coverage.py` reads the `ci.yml` copy only
(`UNIT_STEP`). The three disagree today: `run_tests.sh` omits
`framework/ocaml/{kafka-eio-service,sol-jobs,sol-outbox,sol-runtime}`, `internal/tooling/soldev/test`
and `internal/tooling/style_audit` — six of twelve, including the two suites whose caching bug
BUG-115 is about and the suite that tests the ticket machinery. Separately, enumeration loses whole
suites: `internal/tooling/sol_process/test/test_sol_process.ml` is a root-workspace `(test …)` stanza
named by no runner (compiled by every `dune build`, executed by nothing), and
`examples/pluto/test/` lives in a project with its own `dune-project`, so no workflow runs it at all
— its Dockerfiles are only built. `check_test_reachability.py` cannot see either, because its
default scan root is `cli/test` and its invariant is about modules inside one directory.

## Problem

One authoritative declaration is the goal, and here there are three plus the Dune stanzas, with a
guard that can only see one of them. The guard is correct and its mutation suite passes — which is
the point: it is a well-tested compensation for a duplicated declaration, not a protection of a
product invariant. Meanwhile the enumeration itself is the mechanism that silently drops a suite,
and nothing anywhere checks that a suite is executed by *something*.

## Desired invariant

Each class of evidence has one Dune alias; membership is declared in the owning package's
`test/dune`; the workflow, the pre-push runner and the human-facing runner invoke the alias. Adding
a suite is one line at the suite. A suite that is in no class is a defect that something reports.

## Remediation

Introduce the class aliases (unit, and the classes VERIF-002 owns for infrastructure; the E2E and
lifecycle classes belong here). Move each package's membership next to the package. Make
`ci.yml`, `run_fast_checks.sh` and `run_tests.sh` invoke the aliases; after that
`internal/ci/check_framework_ci_coverage.py` and `internal/ci/test_framework_ci_coverage.sh` have no
subject and are deleted. Adopt the two orphan suites into a class, or record an explicit exclusion
with a reason for each. Note Dune's real limit, verified in the audit: `(tests)` requires `names`
and `:standard` is rejected, which is exactly the legacy registry REFAC-160 removes — do this in
coordination with that migration rather than creating a third convention.

## Acceptance criteria

- No path list of suites exists outside the Dune files; `ci.yml` names classes, not directories.
- `check_framework_ci_coverage.py`, its mutation suite and its `ci.yml` step are gone, and the
  invariant they enforced is demonstrated to be structural: removing a membership line stops the
  suite from running rather than leaving a stale list behind.
- `internal/tooling/sol_process/test` and `examples/pluto/test` are either executed by a class or
  each is recorded as a deliberate exclusion with a reason.
- `run_tests.sh` obtains its membership from the same aliases, so the drift recorded above cannot
  recur.
- Demo/example: `examples/pluto` is the canonical reference application, so if it gains a class this
  is the example in question — state in one line which class runs its suites, or why it stays out.
- Language parity (DEC-022): the TypeScript demo's suites must land in an equivalent class or be
  recorded as deferred with a trigger; state the outcome in one line.

## Completion notes (2026-10-02)

**Premise re-verified** against `origin/main @ 19ab44ab` (after REFAC-161): the unit-suite
directory list appeared in `ci.yml`, `run_fast_checks.sh` and `run_tests.sh`, and
`check_framework_ci_coverage.py` read only the `ci.yml` copy. All three disagreed.

**Implemented.**

- **Membership at the suite.** Each package declares a class alias in its own dune:
  `ci-unit` in `framework/ocaml/{kafka-eio-service,sol-fn,sol-jobs,sol-obs,sol-outbox,sol-runtime,sol-svc,sol-worker}/test/dune`,
  `cli/test/dune`, `internal/tooling/style_audit/dune`, `internal/tooling/soldev/test/dune` and
  `internal/tooling/sol_process/test/dune`; `ci-integration-kafka` in kafka-eio-service;
  `ci-integration-pg` in sol-jobs and sol-outbox; `ci-e2e` in local-demo; `ci-lifecycle` in
  cli/test. Each is `(alias (name <class>) (deps (alias_rec <the suite's own alias>)))`, so the
  class is the recursive alias (`@ci-unit`) and adding a suite is one line at the suite.
- **Consumers name classes.** `ci.yml`: unit → `dune build @ci-unit`, lifecycle → `@ci-lifecycle`,
  integration → `@ci-integration-kafka @ci-integration-pg`, golden path → `@ci-e2e`.
  `run_fast_checks.sh`: `@ci-unit`. `run_tests.sh`: `unit` → `@ci-unit`, `kafka` →
  `@ci-integration-kafka`, new `postgres` → `@ci-integration-pg`, `e2e` → `@ci-e2e`, with
  `HANG_BOUNDS` and the infra requirements updated; `perf.sh`'s `RECORDABLE_SUITES` gains
  `postgres`.
- **The guard is gone.** `internal/ci/check_framework_ci_coverage.py`,
  `internal/ci/test_framework_ci_coverage.sh`, its two `ci.yml` steps and both
  `run_fast_checks.sh` entries are deleted. `@ci-lifecycle` was added to the pre-push fast checks
  so the offline lifecycle failures surface before a push.
- **Orphans.** `internal/tooling/sol_process/test` is adopted into `ci-unit`.
  `examples/pluto/test` is a deliberate exclusion: it is a separate Dune project (its own
  `dune-project`), so a root `@ci-unit` cannot reach it; it is recorded in the `ci.yml` comment
  beside the unit step and its Dockerfiles are built by `example-dockerfile-smoke`.

**A bug carried in from VERIF-002, found here and fixed.** VERIF-002 passed the Postgres URL as a
positional argument to the two pg suites, but `Windtrap.run` parses `Sys.argv` as its own CLI
filter, so the URL matched no test and the suites reported *"20 tests run (20 skipped)"* — a
passing run that executed nothing, in CI as well. Both now call `Windtrap.run ~argv:[||]`, so the
URL is still read from `Sys.argv` and Windtrap's filter stays empty.

**A second failure this branch exposed, in CI.** `@ci-integration-pg` names both database suites, and
one `dune build` runs them concurrently; they destructively own the same `sol_jobs` table, so one
suite's `DROP TABLE` deleted the other's rows mid-test (`one dedupe key per workspace: the beta row
is still pending`). The step and `run_tests.sh`'s `postgres` suite now pass `-j 1` — the
constraint the old step encoded as one invocation per suite. VERIF-007's per-suite schema isolation
removes the need for it.

**Evidence.**

```
$ dune build @ci-unit --force                     # passes
$ dune build @ci-unit --force | grep -c "23 tests run"      # sol_process member: 2
  ... remove the ci-unit stanza from sol_process's dune ...
$ dune build @ci-unit --force | grep -c "23 tests run"      # 1
  ... restore ...
$ dune build @ci-unit --force | grep -c "23 tests run"      # 2
$ _build/.../test_sol_jobs_pg.exe "postgresql://…:5432/sol_dev"
20 failed in 12ms. 20 tests run.            # fail-closed, not skipped
$ bash internal/ci/run_fast_checks.sh
fast checks: 0/67 failed in 14s
```

**Demo/example:** `examples/pluto` is the reference application; it stays out of `ci-unit` as
recorded above (separate project; its Dockerfiles are smoke-built). **Language parity (DEC-022):**
no application-facing contract change; the TypeScript demo has no Dune test target, so it is
unaffected.
