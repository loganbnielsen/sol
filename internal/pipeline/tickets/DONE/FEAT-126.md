---
id: FEAT-126
type: feature
severity: medium
title: "@sol-fab/jobs: a durable leased job queue so a TypeScript worker can hand off retryable work transactionally"
source: "FEAT-118 (split 2026-10-02); DEC-021 amendment 2026-09-29; DEC-022 TypeScript-parity tracking"
---

**Depends on:** None.

**Related:** FEAT-118 (the outcome/DLQ half of the same gap), FEAT-080 (the capability matrix), FEAT-077 (`sol-jobs`, the OCaml library this mirrors), DEC-021, DEC-022.

## Problem

FEAT-113 removed Kafka message-level retry from the OCaml framework and replaced it with `Ack | Fail` (FEAT-118 aligns the TypeScript side). The other half of that amendment is where retryable work now goes: **`sol-jobs`**, a Postgres-backed durable leased job queue (`framework/ocaml/sol-jobs`, FEAT-077). Its defining property is transactional enqueue — `enqueue` is a plain `INSERT`, so calling it with the pool from inside `Db.transaction` puts the job in the *same* Postgres transaction as the state change that caused it, with no dual-write hole.

There is no TypeScript equivalent. FEAT-080's matrix records this as a real parity obligation (not "not applicable"), deferred behind the TypeScript golden path. FEAT-118 originally bundled it; it was split out because it needs a *new published package*, which is a different kind of work from aligning an existing one.

## Remediation

Add `@sol-fab/jobs` (Node/TypeScript), mirroring `sol-jobs`'s contract while keeping the Node ecosystem underneath:

- A shared job table, one row per job, with a workspace/kind discriminator, an encode/decode pair per kind, a lease with a deadline, attempt count and a terminal state — the same shape `sol_jobs.ml` uses.
- `enqueue(pool, { kind, payload, dedupeKey })` as a plain `INSERT ... ON CONFLICT (dedupe_key) DO NOTHING`, so it joins a caller's transaction and is idempotent.
- A runner (`runJobs(...)`, or a `Make`-equivalent factory) hosted by an ordinary `@sol-fab/worker` `-worker` binary — a library, not a fourth primitive (FEAT-077, DEC-021).
- Claim with `FOR UPDATE SKIP LOCKED`, retry with backoff, and a terminal row after the give-up point, matching `sol-jobs`'s observable semantics.

## Acceptance criteria

- `@sol-fab/jobs` exposes a transactional, dedupe-keyed `enqueue` and a leased runner hosted by a `-worker`.
- Its observable semantics (claim-once, lease expiry, backoff, terminal state, idempotent enqueue) match `sol-jobs`'s, demonstrated by tests against Postgres.
- `examples/pluto/app/demo_ts`'s worker enqueues independently retryable work in the transaction that caused it, matching the OCaml `notify_worker` composition.
- FEAT-080's capability matrix records the `sol-jobs` row as aligned.

**Demo/example coverage:** this ticket updates the TypeScript example once the package is published.

## Unblocked (2026-10-02)

`@sol-fab/jobs` now lives in the existing `loganbnielsen/sol-typescript` repo
alongside `@sol-fab/svc` and `@sol-fab/worker` (no new repository was needed), and
its trusted publisher for `release.yml` is configured. `npm trust` cannot be set
for a package that does not exist yet (`404 Package not found`), so `0.1.0` was
bootstrapped with one authenticated publish and carries no provenance; every
release from `0.1.1` on goes through the tag-triggered OIDC workflow with
provenance, like the other packages.

The package is implemented, tested against a real Postgres in CI (14 cases, 0
skipped) and published, so the remaining work is the example update. Promotion to
READY is recording that this ticket is now actionable.

## Done (2026-10-02)

**What landed.**

- `loganbnielsen/sol-typescript#7` (merged `56aa7ac`) adds `packages/jobs` →
  `@sol-fab/jobs@0.1.0`: `enqueue(client, contract, job, { runAt?, dedupeKey? })`
  is a plain `INSERT ... ON CONFLICT (workspace, kind, dedupe_key) DO NOTHING`,
  so passing a `PoolClient` from inside a transaction puts the job in the same
  transaction as the state change that caused it; `runJobs` claims with
  `FOR UPDATE SKIP LOCKED`, renews its lease while the handler runs, retries with
  exponential backoff, fails terminally at the attempt budget and sweeps expired
  terminal rows. Validation rules and `backoffS` mirror `sol_jobs.ml`.
- The package lives in this repo's existing `sol-typescript` repository rather
  than a new one, and CI now runs a Postgres service and passes `POSTGRES_URL`,
  so the queue behaviour is tested for real. `release.yml` gains the `jobs-v*`
  tag and the `jobs` dispatch choice.
- `examples/pluto/app/demo_ts/fulfillment_worker` consumes it: handling an order
  writes `fulfilled_orders_ts` **and** enqueues a `send_confirmation` job in one
  transaction, and hosts the runner alongside its Kafka consumer, stopping it on
  drain. This is the same fact-consumed → job-enqueued composition as the OCaml
  `notify_worker` (which enqueues with `~dedupe_key:msg.id`).

**Checks run.** `sol-typescript` CI: `tsc` clean; 14 jobs cases, 14 pass, 0
skipped (8 pure, 6 against the CI Postgres — idempotent enqueue, enqueue joins
and rolls back with the caller's transaction, claim/handle/complete once,
retry-with-backoff, terminal failure, unreadable-table database error). Demo:
`npm run build -w order-svc -w fulfillment_worker` clean against the published
`@sol-fab/jobs@0.1.0`.

**Publishing.** `npm trust github @sol-fab/jobs` now exists for
`loganbnielsen/sol-typescript` + `release.yml`, but npm refuses to configure
trust for a package that does not exist yet (`404 Package not found`), so
`0.1.0` was bootstrapped with one interactive, 2FA-authenticated `npm publish`
and has no provenance. Every release from `0.1.1` on goes through the
tag-triggered OIDC workflow with provenance, like svc/worker.

**Demo/example coverage.** This ticket *is* the TypeScript example update.

**Language parity.** Closes the `sol-jobs` row of the capability matrix: the
transactional, dedupe-keyed Kafka → job handoff now exists in both languages
with the same observable semantics.

**Follow-up (recorded, not blocking).** The `sol_jobs_processed_total` /
`sol_jobs_job_duration_seconds` name constants are exported from `@sol-fab/jobs`
rather than `@sol-fab/obs`, where the metric-naming vocabulary otherwise lives;
moving them belongs with the next `@sol-fab/obs` release.


