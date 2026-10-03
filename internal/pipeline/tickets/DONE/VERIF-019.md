---
id: VERIF-019
type: refactor
severity: low
title: 'The E2E suite re-asserts library semantics that are already covered at a cheaper Postgres boundary'
source: internal/pipeline/audits/2026-10-02_test_suite_audit.md
---

The E2E suite re-asserts library semantics that are already covered at a cheaper Postgres boundary

**Depends on:** None.

**Premise verified (2026-10-02)** against `origin/main @ 310917dd`:
`internal/fixtures/local-demo/test/test_e2e.ml` asserts sol-jobs retry counts at `:1244-1255`,
outbox duplicate/suppression semantics at `:1206-1214` and per-key ordering at `:1215-1222`.
Each has a dedicated Postgres test: `framework/ocaml/sol-jobs/test/test_sol_jobs_pg.ml`
(`test_stale_retry_is_a_no_op`, `test_retry_policy`/backoff cases) and
`framework/ocaml/sol-outbox/test/test_sol_outbox.ml` (`test_a_failed_publish_does_not_advance_the_key`,
`test_per_key_order_is_not_insertion_order`, `test_duplicate_enqueue_with_a_dedupe_key_is_a_no_op`).

## Problem

The E2E class exists to verify the *composition* — a request reaches Kafka, a worker consumes it, a
durable effect is visible, the metric and log are emitted for that transaction — and that is the
only thing no cheaper suite can assert. The retry-count, per-key-order and dedupe-detail assertions
are sol-jobs/sol-outbox semantics re-checked at the most expensive boundary: E2E needs Postgres
**and** a broker **and** Loki and runs under `--force` for 180 s, while the library suites need only
Postgres. Worse, per `VERIF-014`/`VERIF-015`, those are precisely the assertions that silently
short-circuit when the E2E dependencies are absent, so the expensive copy is also the weaker one.

## Desired invariant

Each claim is asserted once, at the cheapest boundary that can establish it. The E2E class asserts
composition and end-to-end observable effects; library semantics stay in the library suites that
already own them.

## Remediation

Keep in E2E only the assertions that composition makes meaningful (the order and framing of an
end-to-end transaction, durable effect visible, metric/log emitted); delete the retry-count,
per-key-order and dedupe-detail cases and point at the library tests that own them. Where a
composition assertion needs a fact only the library can produce, expose it as a value in the E2E
fixture rather than re-deriving it.

## Acceptance criteria

- `test_e2e.ml` no longer asserts retry counts, per-key ordering or dedupe cardinality that
  `test_sol_jobs_pg.ml` / `test_sol_outbox.ml` already establish.
- The E2E suite still asserts the composed transaction end to end (HTTP → Kafka → worker → durable
  effect → metric/log).
- Demo/example: the E2E fixture is the demo's own test; no separate example change.
- Language parity: no application-facing contract change; state that in one line.

## Completion (2026-10-02)

Deleted the three E2E cases that re-asserted library semantics at the most
expensive boundary, and removed the fixture work that fed only them:

- retry counts (`a transient job failure retries in sol-jobs...`) — owned by
  `framework/ocaml/sol-jobs/test/test_sol_jobs_pg.ml`;
- per-key ordering (`a blocked earlier event...`) — owned by
  `framework/ocaml/sol-outbox/test/test_sol_outbox.ml`
  (`test_per_key_order_is_not_insertion_order`);
- dedupe cardinality (`a duplicate fact delivery...`) — owned by
  `test_sol_outbox.ml` (`test_duplicate_enqueue_with_a_dedupe_key_is_a_no_op`,
  `test_a_failed_publish_does_not_advance_the_key`).

The retry-injection in the outbox `Effect` handler and the `dupe`/`order`
fixture segments are gone with them. The suite still asserts the composition:
HTTP → Kafka → worker → durable row + `sol-jobs` effect; outbox publish → Kafka
→ worker → idempotent effect; rollback leaves nothing; a broker outage holds the
intent and recovery publishes it once; a crash between the broker ack and the row
mark duplicates rather than losing; `Fail` stops the consumer with no retry/DLQ
topic; the metrics and Loki lines are emitted. The class is 16 cases (was 19).

Evidence: `dune build @ci-e2e --force` → 16 tests pass.

- Demo/example: the E2E fixture is the demo's own test; no separate example
  change. Language parity (DEC-022): no application-facing contract change.
