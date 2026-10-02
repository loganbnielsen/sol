---
id: VERIF-002
type: refactor
severity: high
title: An integration suite's dependency is part of its definition, not of the caller's environment
source: internal/pipeline/audits/2026-10-01_verification_architecture_audit.md
premise: rg -q -e setenv -e POSTGRES_URL -e postgresql:// framework/ocaml/sol-jobs/test/dune
---

An integration suite's dependency is part of its definition, not of the caller's environment

**Depends on:** None.

**Premise verified (2026-10-01)** against `origin/main @ fd138b3a`: `framework/ocaml/sol-jobs/test/dune`
and `framework/ocaml/sol-outbox/test/dune` declare plain `(tests …)`/`(test …)` stanzas whose suites
read `POSTGRES_URL` from the ambient environment and print `[skip] POSTGRES_URL not set` when it is
absent; `.github/workflows/ci.yml` runs them from the unit step (no `--force`) and again from the
integration step, where Dune serves the second invocation from the first one's cache. Reproduced
generically in the audit: run 1 under an unset variable executed and recorded a skip, run 2 under a
set variable exited 0 without executing anything, and only `--force` executed it. The alias form
(`dune build @dir/runtest-integration`) is cached identically. Dune has no environment-dependency
construct — `(deps env:VAR)` fails with *No rule found for test/env:VAR* and `(deps (env VAR))` is a
syntax error — so a target whose behaviour or dependency address comes from the caller cannot have
coherent cache semantics.

## Problem

BUG-115's fix (PR #860) makes the two database suites their own targets, which stops the unit step
from building them. That is a real improvement, and it leaves the class unsolved: target
disjointness is what keeps the two runs apart today, and the target still means "connect to whatever
`POSTGRES_URL` names in this shell". Observed consequence: once the alias has been built, invoking
it again with `POSTGRES_URL` unset is a cache hit, so the fail-closed `with_pool` never executes and
the run is green. The same gap applies to `internal/fixtures/local-demo/test/`, whose suite needs
`--force` on every CI invocation to be sure it ran, and to any future integration target.

## Desired invariant

An integration target's dependency is part of the target. The connection address and the
provisioning it needs are supplied by the build definition (the package's own `dune`, with the
provisioning step as an explicit dependency of the rule), so invoking the target twice under two
different ambient environments is the *same action*, and a second invocation either re-runs it or
is a legitimate cache hit of a run that really happened. No suite consumes a dependency by ambient
variable alone, and no integration step needs `--force` to be believed.

## Remediation

For each infrastructure class, declare one alias whose rules pin the address they use; keep the
fail-closed entry points introduced for BUG-115 (a missing database is a failed run, not a skip).
Where a suite genuinely must read an address from outside, make the harness pass it explicitly to
the suite rather than letting the suite discover it, so the value is part of the invocation.
Prefer this over `--force`, which forces every action in the build and hides the same problem in a
new place.

## Acceptance criteria

- An integration class target, invoked twice in one `_build` under different ambient variables,
  either runs both times or fails — never exits 0 having executed nothing. Demonstrate this with the
  scratch-project reproduction recorded in the audit and record the command in the completion notes.
- No integration target requires `--force` to be a trustworthy observation.
- Every infrastructure suite still fails when its dependency is absent, with a message naming the
  dependency.
- Demo/example: not applicable — test topology and dependency declaration only; no app-author
  surface changes. Language parity (DEC-022): no application-facing contract changes, but the
  TypeScript golden-path suite needs the same treatment if it acquires a database-backed target;
  note the outcome in one line.
