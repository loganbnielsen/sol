---
id: FEAT-113
type: refactor
severity: high
title: Remove Kafka message-level retry and application-level Dead_letter
source: DEC-021 amendment (2026-09-29) — Kafka distributes facts; jobs perform retryable work
premise: "! rg -q 'Make_with_retry' framework/ocaml/sol-worker/lib/worker.mli"
---

**Depends on:** BUG-099, FEAT-112.

`FEAT-112` is a dependency, not merely related work. Removing message-level retry
makes Kafka → `sol-jobs` the endorsed composition for independently retryable work,
and that composition is not safe until `enqueue` deduplicates. Landing the deletion
first would replace a working mechanism with a recommended one that still carries the
Kafka↔Postgres at-least-once hole.

**Related:** `DEC-021` (the amendment this implements), `FEAT-111` (the outbox),
`FEAT-114` (the operation-retry helper), `FEAT-078` (the two-tier split this
collapses), `BUG-104` and `BUG-097` (retry-path units this makes moot), `DOCS-015`.

## Decision

Settled by the operator on 2026-09-29 and recorded in `DEC-021`'s amendment:

- **Application-level `Dead_letter` is removed.** Once a valid decoded fact reaches
  the handler, the outcome is exactly `Ack | Fail`. A handler that declines to apply a
  fact fails, and the offset does not advance. It does not get to declare a fact
  permanently unprocessable and advance past it — that would violate the amendment's
  invariant that Sol must not advance past a fact it did not successfully consume —
  and it spares application code having to make a reliable "this can never succeed"
  judgment at runtime.
- **Framework decode and schema failures keep their DLQ.** The handler never received
  a domain fact there, so parking the record is transport/schema failure handling, not
  a skipped fact.
- A permanent semantic mismatch, an unsupported domain version, or an invariant
  violation is evidence that the consumer, the deployment, or the contract is wrong.
  It surfaces as a stopped consumer and an operator-visible contract failure.
- If a concrete workload ever shows that a decoded fact should legitimately not block
  its consumer, the answer is an explicitly named semantic primitive designed against
  that workload — not a generic escape hatch preserved in advance.

## Premise

Checked 2026-09-29 at `origin/main` `d27f8710`: `Make_with_retry` exists in the
public worker interface, `Worker.Retry`/`Worker.Dead_letter` and `retry_policy` are
public, and `Kafka_service.Retry_topics` plus the retry relay exist in
`kafka-eio-service`. The probe is stale exactly when the retry surface is gone.

## Why the prerequisite

BUG-099 must land first. `kafka_service_config.ml` fixes `partitions = 1`, so `Fail`
would stop *all* processing for the worker — not just the affected key — and a live,
heartbeating consumer never hands the only partition to a standby. Removing retry
before contract-driven partitioning exists converts a rare poison record into a
whole-worker outage. This deletion is what turns BUG-099 from a bug fix into a
load-bearing contract.

## What this removes

`Make_with_retry`, `RETRYABLE_WORKER`, `~retry_policy`, `retry_strategy`,
`retry_policy`/`default_retry_policy`, `Worker.Retry`, `Worker.Dead_letter`, the
retry-topic relay and its consumer, `X-Sol-Retry-Attempt` and `X-Sol-Retry-At`,
group-scoped retry topics, and the retry-partition head-of-line limitation. `Make`
becomes the single tier, and its `handle` returns the two-case `Ack | Fail` outcome.

## What stays

- DLQ publication for decode and schema failures. The per-group DLQ naming and
  provenance rules from `DEC-021`'s DLQ amendment are unchanged.
- The acknowledgement-ownership invariant: the framework commits the offset, never
  the handler.

## Mooted units

`BUG-104` (release retry-topic records by due time) and `BUG-097` (honour shutdown in
Retry_topics workers) describe the machinery this removes. When this lands, reconcile
them explicitly — point each at the removal rather than silently closing it.

## Acceptance criteria

- No retry mechanism, and no application-level `Dead_letter`, remains in the
  `sol-worker` or `kafka-eio-service` public API, or in the generated scaffold.
- The worker outcome vocabulary is exactly `Ack | Fail`, and the ack-ownership
  invariant is preserved.
- A `Fail` does not advance the offset, surfaces a metric and an alert, and is tested
  against a real broker.
- DLQ delivery for a decode or schema failure still works and is tested.
- `sol-worker.md`, `kafka-eio-service.md`, the tutorial, the alert runbooks, and
  `examples/pluto`/venus describe one mechanism.
- `BUG-104` and `BUG-097` are reconciled in the completion notes.
- TypeScript parity: `@sol-fab/worker`'s retry and `dead_letter` semantics are aligned,
  or the delta is recorded with a trigger (DEC-022).

**Demo/example coverage:** pluto/venus and the tutorial must show the new contract — a
fact consumed, and an independent effect handed to `sol-jobs` rather than retried on
the stream.

## Recon (2026-09-30) — scope and the order that keeps the tree compiling

Premise re-verified against this tree, not the ticket's snapshot: `Make_with_retry`
is still public in `framework/ocaml/sol-worker/lib/worker.mli`, so the finding holds.

Size of the removal, measured:

| Unit | Lines | Disposition |
| --- | --- | --- |
| `kafka-eio-service/lib/kafka_service_retry_topics.ml` / `.mli` | 649 / 129 | deleted wholesale — this *is* the relay and its consumer |
| `sol-worker/lib/worker.mli` | 122 | `Ack \| Retry \| Dead_letter` → `Ack \| Fail`; `RETRYABLE_WORKER`, `retry_policy`, `default_retry_policy`, `Make_with_retry` (declared twice, at `:56` and `:100`) all go |
| `sol-worker/lib/worker.ml` | 488 | single `Make` tier, two-case outcome |
| `kafka-eio-service/lib/kafka_service*.ml` | — | retry-topic creation in `register`, the relay hooks (`on_relay_publish`, `on_retry`), `Retry_topics` in the public surface |
| `sol-worker.md` / `kafka-eio-service.md` | 247 / 417 | rewritten to one mechanism |

**Scoping trap, checked rather than assumed:** `retry_policy` also appears in
`sol-jobs` (`sol_jobs.ml`, `sol_jobs.mli`, `sol-jobs.md`, its tests). That is *job*
retry — a leased Postgres attempt budget — and is unrelated to message-level Kafka
retry. It stays untouched. A grep-driven removal would have deleted it.

**Removal order** (a public-API removal has no safe partial state — `Dead_letter`
alone cannot go first, because the retry relay switches on it):

1. `kafka-eio-service`: drop the relay, retry-topic provisioning and the retry hooks,
   keeping decode/schema DLQ publication.
2. `sol-worker`: collapse to one `Make` tier with `Ack | Fail`, and drop
   `RETRYABLE_WORKER` / `retry_policy` / `default_retry_policy`.
3. Call sites: `examples/pluto`, venus, `internal/fixtures/local-demo/bin/retry_demo.ml`
   (which exists only to exercise retry), the scaffold, and the integration tests that
   drive the relay.
4. Docs, then the tests the acceptance criteria name.

**Base branch:** this work is based on `BUG-099/partition-contract`, because FEAT-113
depends on BUG-099 being in `DONE` and only that branch has it until PR #767 merges.
Rebase onto `main` once it does. (PR #767 merged as `e19695ec`; this branch is based
on it.)

## Completion notes

Implemented 2026-09-30 on `FEAT-113/remove-kafka-retry`.

**Premise.** Re-verified at pickup: `Make_with_retry` was still public in
`framework/ocaml/sol-worker/lib/worker.mli` and the relay still lived in
`kafka_service_retry_topics.ml/.mli`, so the work was still missing.

**What changed.**

- `kafka-eio-service`: `kafka_service_retry_topics.ml/.mli` deleted; a new
  `Kafka_service.Dlq` keeps the relay record, `decode_failure_message`,
  `route_decode_error`, and the canonical group-scoped DLQ naming (BUG-080).
  `Kafka_service.consume` gained `?decode_error_policy` (default `Route_to_dlq`)
  and lost `?on_decode_error`; `Retry_topics`, `consume_partitioned`,
  `consumer_hooks`/`no_hooks`, and `on_relay_publish` are gone.
- `sol-worker`: single `Make` tier; `outcome = Ack | Fail`; `RETRYABLE_WORKER`,
  `retry_policy`, `default_retry_policy`, `Make_with_retry`, `ack_outcome`, and
  `retry_strategy` gone. A `Fail` does not ack, emits
  `sol_worker_messages_total{status="fail"}`, logs, and returns
  `Kafka.Consumer.Stop` (so `run` returns `Ok ()`).
- Call sites migrated: `examples/pluto`, `internal/fixtures/venus`,
  `internal/fixtures/local-demo` (`retry_demo.ml` deleted), and both scaffold
  templates (`platform/shared/.../notify_worker`, `.../worker`).

**Contract-visible changes.**

- `consume`'s decode-error default flips from `Ack_and_drop` (silent drop) to
  `Route_to_dlq`. Deliberate — decode/schema failures keep their DLQ. A plain
  `Make` worker now dead-letters by default where it previously acked and dropped.
- `sol_worker_messages_total`'s `status` vocabulary shrinks to exactly
  `ok`/`fail`/`ack_failed`; `retry`, `dead_letter`, `relay_published`, and
  `relay_failed` are gone, and the `SolWorkerRelayPublishFailed` and
  `SolWorkerDeadLetterInflow` alert rules are removed with them.
- `Fail` stops the consumer with the offset uncommitted.

**Demo/example coverage.** `examples/pluto` and `internal/fixtures/venus` both
consume a fact and hand an independent effect to `sol-jobs`:
`Pg_db.transaction` inserts the row and calls `Jobs.enqueue ~dedupe_key` in the
same transaction, and the worker binary hosts a `Sol_jobs` poller. Each workspace
gains `db/migrations/0002_sol_jobs.sql`. `docs/guides/TUTORIAL.md` describes the
same composition, and `local-demo` (FEAT-112) already showed it.

**Validation.**

- `dune build @all` clean.
- `dune test framework/`: sol-worker 16, kafka-eio-service 28.
- Broker-backed integration (`runtest-integration --force`): 13, including
  `ack_ownership` (an unacknowledged fact is redelivered to its group, not
  skipped) and `decode_error_policy` (a decode failure is parked on the group's
  DLQ while the next record flows).
- `internal/fixtures/local-demo/test/`: 9, including the sol-jobs handoff.
- `dune exec internal/fixtures/venus/bin/run.exe` against Redpanda + Postgres:
  `sol_worker_messages_total{status="ok"} 3` and
  `sol_jobs_processed_total{kind="send_receipt_email",status="ok"} 3`.
- `examples/pluto` tests pass.
- `check_ocamlformat.sh --all`, `check_framework_doc_signatures.py`,
  `check_no_comments.sh`, `check_production_infra.py` (terraform fmt), and
  `soldev pipeline validate` (887 tickets) all pass.

**Mooted units.** BUG-104 moved to `DONE/` in this branch, pointing at the
removal. BUG-097 was already `DONE` (closed by BUG-102) against the retry path
this removes.

**TypeScript parity (DEC-022).** OCaml: implemented. TypeScript: intentionally
deferred — `@sol-fab/kafka`/`@sol-fab/worker` (external npm packages) still expose
the retry-topic relay and `Ack | Retry | Dead_letter`, and
`examples/pluto/app/demo_ts/fulfillment_worker` pins them. Delta recorded in
**FEAT-118** (BACKLOG), triggered by the next `@sol-fab/*` release.

**Remaining limitations.** None functional. The scaffold's generated worker shows
the two-case contract but a plain insert rather than the `sol-jobs` handoff; the
handoff is demonstrated in pluto, venus, and the tutorial, and moving the scaffold
to the same composition is optional follow-up.

