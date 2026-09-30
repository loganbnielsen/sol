---
id: FEAT-114
type: feature
severity: medium
title: Provide a shared bounded operation-retry helper
source: DEC-021 amendment (2026-09-29) — Kafka distributes facts; jobs perform retryable work
---

**Depends on:** None.

**Related:** `DEC-021` (the amendment; supporting work), `FEAT-113` (the deletion
that makes this the normal path), `pg-eio`, `aws-eio`, `kafka-eio` (the dependency
calls it wraps), `FEAT-112` (`sol-jobs`' retry policy, whose vocabulary this should
share).

## What this is

The amendment removes message-level retry and puts transient failures at the
operation level: retry the dependency call, not the handler. The framework has no
shared helper for that — retry logic exists only inside the retry-topic machinery and
`sol-jobs` — so today a transient `pg-eio` or `aws-eio` failure is swallowed, raised
into a fail-stop, or retried by hand-rolled code in every application.

This is **follow-up supporting work, not a migration prerequisite**: it does not gate
`FEAT-113`, because an application can already implement a correct bounded retry. Its
absence is an ergonomics gap, not a correctness hole.

## Required behaviour

- One bounded, jittered, non-blocking retry helper over an
  `(unit -> ('a, 'e) result)`-shaped operation, using the policy vocabulary
  `sol-jobs` and `sol-worker` already use — `base_delay_s`, `max_delay_s`,
  `max_attempts`, `jitter_ratio` — so there is one retry vocabulary, not three.
- It retries **operations, never messages**: it must not become a way to re-run a
  handler, or a route back to message-level retry.
- It yields to Eio between attempts; it never blocks the domain.
- Exhaustion returns the last error, and the caller decides `Fail` or a job.
- It is usable from `-svc`, `-worker` and `-fn`.

## Non-goals

- Not a message-retry mechanism, and not a scheduler.
- Not a policy engine; no per-error-class routing in the first version.
- Not a substitute for idempotency or for `sol-jobs`.

## Acceptance criteria

- The helper is public, documented, and used by at least one generated or example
  path.
- Its policy vocabulary matches `sol-jobs` and `sol-worker`.
- A test covers success after retry, exhaustion, cancellation, and jitter bounds.
- It is documented as operation-level, with the message-level alternative explicitly
  rejected.

**Demo/example coverage:** the tutorial shows an operation retried in place,
contrasting with handing independent work to `sol-jobs`.

**TypeScript parity:** record the verdict — a TS equivalent in `@sol-fab/*`, or a
tracked follow-up with a trigger (DEC-022).
