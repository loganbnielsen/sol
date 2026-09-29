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
