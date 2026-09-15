---
id: DOCS-015
type: docs-finding
severity: low
source: FEAT-076 acceptance-criterion gap found in worker retry semantics review 2026-09-14
---

**Depends on:** None.

**Related:** FEAT-076, DEC-021, BUG-028, BUG-029, BUG-030, FEAT-078.

FEAT-076's acceptance criteria required ordering and duplicate-delivery tradeoffs to be
documented in the `sol-worker`/`kafka-eio-service` spec doc. That was only partly done.

The retry strategy section of `framework/kafka-eio-service/kafka-eio-service.md` says the
retry backoff "blocks only its own partition, not the whole retry topic" and names only
per-key serialization as the limitation. It does not state the three facts below, and
`framework/sol-worker/sol-worker.md` does not either.

## Required documentation

1. **Retry delay serializes every record sharing the retry partition, not merely the same
   key.** Because the retry topic is sharded across the source partition count by key
   hash, unrelated keys collide on a retry partition, and a retry waiting for its delay
   head-of-line blocks every later record in that partition — including unrelated keys.
2. **Republishing a retry permits it to execute after later source-partition records.**
   A retried message re-enters Kafka at a later offset, so it may be processed after
   records that originally followed it, including later records with the same key.
   Applications requiring strict source-partition or per-key order must not assume
   `Retry_topics` preserves it.
3. **The head-of-line bound is a steady-state bound.** In steady state, extra delay is
   bounded roughly by the configured maximum retry backoff. Under backlog or overload,
   actual delay is unbounded, because Kafka itself is the buffer.
4. **Point at the acknowledgement ownership invariant** in `framework/sol-worker/sol-worker.md`
   wherever ack/drop behavior is described, rather than restating it — the invariant is the
   single source of truth for the retry, dead-letter, decode-failure, and exhaustion paths.

`In_memory` documentation must also state explicitly that a retry pauses processing of
that Kafka partition for the retry delay.

## Acceptance criteria

- The retry section of `kafka-eio-service.md` states all three facts above.
- `sol-worker.md` states the ordering and duplicate-delivery tradeoffs, or links to the
  `kafka-eio-service.md` section that does.
- The `In_memory` partition-pause behavior is stated where `In_memory` is documented.
- Ack/drop behavior in the retry docs links to the acknowledgement ownership invariant
  rather than re-describing it.
- No doc implies precise scheduling, preserved per-partition ordering, or a bounded
  delay under overload.

## Non-goals

- Documenting retry buckets, Postgres-backed retries, or `sol-jobs` (none exist).
- Changing runtime behavior — this is documentation only.
