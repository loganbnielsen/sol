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

## Blocked On

A published `@sol-fab/jobs`. The package needs a repository home and npm trusted publishing (`npm trust github …`, 2FA-gated) before it can be released through the normal mechanism — operator action, not an engineering blocker. Until then this ticket stays in BACKLOG; FEAT-118 (the outcome/DLQ half) does not depend on it.
