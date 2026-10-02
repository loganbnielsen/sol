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

## Completion notes (2026-10-02)

**Premise re-verified** against `origin/main @ 19ab44ab` (after REFAC-161): all three
infrastructure targets took their address from the caller. `test_sol_jobs_pg.ml` and
`test_sol_outbox.ml` read `POSTGRES_URL`; `test_kafka_service_integration.ml` read the `KAFKA_*`
variables; `ci.yml` supplied them in the step `env:`, and the golden path ran under
`dune test internal/fixtures/local-demo/test/ --force`.

**Implemented.**

- `framework/ocaml/sol-jobs/test/dune` and `sol-outbox/test/dune` pass the Postgres URL as an
  argument in their `runtest-integration` rule; the suites read `Sys.argv` and fail naming the dune
  file when no address is given (the BUG-115 fail-closed behaviour, kept).
- `framework/ocaml/kafka-eio-service/test/dune` sets `KAFKA_SECURITY_PROTOCOL`, `KAFKA_BROKERS`,
  `SCHEMA_REGISTRY_URL` and `REDPANDA_ADMIN_URL` in its rule.
- `internal/fixtures/local-demo/test/dune` becomes an `(executable …)` plus a `runtest` rule that
  pins the six addresses the golden path reads; `ci.yml` and `run_tests.sh` no longer supply them
  and no longer use `--force` for these targets.
- `ci.yml`'s integration step keeps only `start-redpanda.sh`/`ensure-postgres.sh`; the golden-path
  step invokes `@internal/fixtures/local-demo/test/runtest` without `--force`. The Loki push in the
  suite is now non-fatal, so an unreachable Loki skips rather than aborting the golden path; the
  local runner still starts Loki, so its assertions run there.

**Evidence** — the audit's scratch reproduction, inverted, in `/tmp/verif002`:

```
$ ADDRESS=one dune build @ambient            # address comes from the caller
ran against one
$ ADDRESS=two dune build @ambient            # cache hit: exit 0, executed nothing
$ ADDRESS=two dune build @ambient --force
ran against two
$ ADDRESS=one dune build @pinned             # address is part of the definition
ran against postgresql://postgres:dev@localhost:5432/sol_dev
$ ADDRESS=two dune build @pinned             # same action; ambient value ignored
```

With the address in the definition the two invocations are one action, so the second is a
legitimate cache hit of a run that really happened; the ambient target's second run is a false
success. Fail-closed: `_build/default/framework/ocaml/sol-jobs/test/test_sol_jobs_pg.exe` with no
argument fails all 20 cases with *"no Postgres address: the runtest-integration alias in
framework/ocaml/sol-jobs/test/dune pins one…"*, and sol-outbox's 7 cases likewise.

**Checks:** `dune build`; `check_framework_ci_coverage.py` (7 unit packages and 3 integration
aliases, all covered); `check_no_comments.sh`; `ci.yml` parses; `run_fast_checks.sh` 0/67. Docker
is unavailable in this environment, so the real Postgres/broker aliases were not executed here —
CI's integration step is the authority for that.

**Out of scope here:** `run_tests.sh`'s unit step keeps `--force` (it is not an integration
target). VERIF-007 owns per-suite schema isolation; VERIF-006 owns the Loki self-skip the golden
path now pins a URL for.

**Demo/example:** not applicable — test topology and dependency declaration only. **Language
parity (DEC-022):** no application-facing contract change; the TypeScript golden path has no
database-backed Dune target, so there is nothing to mirror.
