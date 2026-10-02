---
id: VERIF-007
type: refactor
severity: medium
title: Serialization stands in for isolation — one Postgres fixture destructively owned by two suites
source: internal/pipeline/audits/2026-10-01_verification_architecture_audit.md
---

Serialization stands in for isolation — one Postgres fixture destructively owned by two suites

**Depends on:** VERIF-002.

**Premise re-verified (2026-10-01)** against `origin/main @ fd138b3a`:
`platform/local/scripts/ensure-postgres.sh` provisions one container (`sol-postgres`), one port
(5432) and one database (`sol_dev`), with no per-suite schema or database;
`framework/ocaml/sol-jobs/test/test_sol_jobs_pg.ml` and
`framework/ocaml/sol-outbox/test/test_sol_outbox.ml` each begin with
`DROP TABLE IF EXISTS sol_jobs` and recreate the same table, which is why BUG-115 observed
`relation "sol_jobs" does not exist` raised from the other suite's `DROP TABLE` when a single
`dune test` invocation ran both. PR #860's remedy is one alias per invocation. The sibling Kafka
class already isolates properly instead: `internal/fixtures/local-demo/test/test_e2e.ml:213-217`
derives its topic from `Unix.getpid ()` and
`framework/ocaml/kafka-eio-service/test/test_kafka_service_integration.ml:18-23` from a random
`run_id`.

## Problem

Two suites that share a database also share a destructively recreated object, so their isolation is
a property of the *scheduler* rather than of the resource name. Making that a CI sequencing rule
puts product/test semantics into `.github/workflows/ci.yml` — the one place the verification model
should not live — and it means a developer running `dune test` locally can still hit the
interleaving. The fix also forecloses safe parallelism, which the class can otherwise afford.

## Desired invariant

Two suites may share a database server, and may not share a destructive object. Isolation comes from
unique resource naming (schema or database per suite, per run), the way the Kafka class already does
it. Provisioning stays shared; ownership does not.

## Remediation

Give each Postgres-backed suite its own schema or database, created by the suite's own DDL and
derived from the suite name plus a per-run suffix, and drop the `DROP TABLE IF EXISTS sol_jobs`
ownership of a shared object. Then the "one alias per invocation" rule in `ci.yml` can be deleted
because the same invocation is safe, and the Postgres class can run in parallel with itself. Do not
reach for serial execution if unique naming is this cheap.

## Acceptance criteria

- Two Postgres suites run in one `dune` invocation, repeatedly, without either observing the other's
  DDL; the interleaving BUG-115 recorded cannot be reproduced.
- No workflow step exists solely to keep two suites from colliding.
- Each suite's DDL creates the object it owns and names it uniquely; no suite drops an object it did
  not create.
- Demo/example: not applicable — test fixtures only. Language parity (DEC-022): the TypeScript
  golden path's Postgres usage should follow the same naming convention if it acquires a
  database-backed suite; record the outcome in one line.
