---
id: INFRA-095
type: infra
severity: medium
source: "BUG-067 review, 2026-09-29: the CI unit step excludes framework/ocaml/kafka-eio-service/, and framework/ocaml/sol-jobs/ was never listed at all"
title: Run every framework package's unit suite in CI
---

Run every framework package's unit suite in CI

**Depends on:** None.

## Problem

CI's *Unit tests (no broker/Postgres/Loki required)* step ran
`framework/ocaml/sol-env/ framework/ocaml/sol-fn/ framework/ocaml/sol-obs/
framework/ocaml/sol-runtime/ framework/ocaml/sol-svc/ framework/ocaml/sol-worker/
cli/test/ internal/tooling/style_audit/ internal/tooling/soldev/test/`, with a
comment explaining the omission of `framework/ocaml/kafka-eio-service/`: that
package's `test/dune` declared *both* its offline unit suite and its
broker-requiring integration suite as `(test …)`, so `dune test <dir>` would run
both and the runner has no broker.

Two consequences, both silent:

- `kafka-eio-service`'s 41 offline unit tests — the schema-registry decode,
  retry-topic naming, relay and config paths — ran **only** through
  `run_tests.sh`'s `run_kafka()`, which is not the PR gate. A PR could break them
  and stay green.
- `framework/ocaml/sol-jobs/` was never in the list at all, so its 11 offline
  tests (including the config-boundary timing cases added by
  CODEX_STYLE_AUDIT-079) ran nowhere on the PR gate either. Its Postgres case
  already skips when `POSTGRES_URL` is unset, so nothing about it justified the
  omission.

The cause of the first is a missing *boundary*: a suite that needs infrastructure
should not be reachable from the command that runs the offline suites.

## Remediation

Make infrastructure-requiring suites unreachable from `dune test <dir>` rather
than excluding the package that contains them:

1. `framework/ocaml/kafka-eio-service/test/dune`: the integration suite becomes
   an `executable` behind a `(rule (alias runtest-integration) …)`, the shape
   kafka-eio's own repository already uses for the same split.
2. The CI unit step lists every framework package, including
   `kafka-eio-service` and `sol-jobs`.
3. `run_tests.sh`'s `run_kafka()` builds the `runtest-integration` alias instead
   of `dune test <dir>`.
4. A guard holds the invariant, because "the list is complete" is exactly the
   kind of fact that rots: `internal/ci/check_framework_ci_coverage.py` reads
   `ci.yml` as YAML, finds the unit step, enumerates `framework/ocaml/*/test/dune`
   files that declare a unit `(test …)` stanza, and fails naming any package the
   step does not run — with `internal/ci/test_framework_ci_coverage.sh` as its
   mutation test (a missing package fails and is named; the covered tree passes;
   an integration-only package is not required).

## Acceptance criteria

- The unit step runs every framework package's unit suite, and no package is
  excluded for building an infrastructure-requiring suite.
- The broker-requiring suite still runs, through the alias, in `run_tests.sh`
  and in the `golden-path-smoke`/integration path; its test count is unchanged.
- The guard fails when a package with a unit suite is dropped from the unit step
  or a new one is added without listing it, and passes on the committed tree.

## Completion (2026-09-29)

- **Premise verified** at origin/main `ed21c195`: the step's comment named
  `framework/ocaml/kafka-eio-service/` as excluded because "its test/dune also
  builds a broker-requiring integration suite"; `framework/ocaml/sol-jobs/`
  appeared in neither the CI step nor `run_tests.sh`'s offline command.
- **Change.** `framework/ocaml/kafka-eio-service/test/dune` declares the
  integration suite as an `executable` behind `runtest-integration` (its 17 tests
  moved from `dune test` to the alias, verified: `dune test
  framework/ocaml/kafka-eio-service/` runs only `kafka_service`, 41 tests, and
  `dune build @framework/ocaml/kafka-eio-service/test/runtest-integration` runs
  all 17 against a live broker). The CI unit step now lists every framework
  package (`kafka-eio-service` and `sol-jobs` added), and `run_tests.sh`'s
  `run_kafka()` builds the alias. New: `internal/ci/check_framework_ci_coverage.py`
  plus `internal/ci/test_framework_ci_coverage.sh` (four expectations: missing
  package fails and is named, covered tree passes, integration-only package is
  not required, committed tree passes) and their two CI steps.
- **The infrastructure-backed half, added in the same PR.** Moving the suite out
  of `dune test` is only half the fix: it also has to run somewhere on the PR
  gate, and until now it ran only in `run_tests.sh`. The `test` job now starts
  Redpanda (`platform/local/scripts/ensure-broker.sh` — one container serving
  Kafka 9092, schema registry 8081 and the admin API 9644) and Postgres
  (`ensure-postgres.sh`) and runs both suites that need them: the
  `runtest-integration` alias (15 tests) and `framework/ocaml/sol-jobs/`, whose
  Postgres case now *runs* instead of skipping — 8 tests that the PR gate had
  never executed. Both scripts are the ones `sol local infra up` uses, so CI and
  the developer loop cannot drift. Verified locally by running the step's exact
  commands against the local containers: `dune build
  @framework/ocaml/kafka-eio-service/test/runtest-integration` and
  `dune test framework/ocaml/sol-jobs/` with the step's environment.
- **The guard covers both directions.** `check_framework_ci_coverage.py` now also
  fails when a `runtest-integration` alias under `framework/` is built by no CI
  step — the mirror invariant, since a suite moved to an alias to leave `dune
  test` must not leave the gate — and `test_framework_ci_coverage.sh` gained the
  matching expectation (an unbuilt alias fails and is named).
- **Validation.** `dune build`, `dune test framework/ocaml/kafka-eio-service/
  framework/ocaml/sol-jobs/` (41 + 11 tests, no broker needed), the integration
  alias against the local Redpanda (17 tests), `check_no_comments.sh`,
  `check_ocamlformat.sh --all`, and the guard's own mutation test. CI's
  `test` job exercises the new step list and the guard on this PR's head.
- **Demo/example:** not applicable (CI wiring and a guard; no app-author
  surface). **Language parity:** not applicable (no framework or application
  contract changes).
