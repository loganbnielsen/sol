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
