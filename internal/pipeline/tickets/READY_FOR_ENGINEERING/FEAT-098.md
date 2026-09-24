---
id: FEAT-098
type: feature
severity: medium
source: internal/pipeline/tickets/DONE/BUG-051.md
---

TypeScript: route source-topic decode failures to the DLQ under `retry-topics`, matching OCaml's `decode_error_policy`

**Depends on:** None.

**Language-parity tracking for:** BUG-051 (DEC-022 capability matrix: retry/DLQ semantics).

## Problem

BUG-051 made OCaml's `Retry_topics` send an undecodable source record, raw, to
the group-scoped DLQ with `X-Sol-Decode-Error` and `X-Sol-Origin-Group`, acking
only after that publish succeeds (`decode_error_policy = Route_to_dlq`, the
default), with `Ack_and_drop` as the explicit opt-in. `@sol-fab/kafka` still
acks and drops: `wrapEachRetryableMessage` (github.com/loganbnielsen/sol-kafka,
`src/retryable.ts` lines 80-88 as of 2026-09-24) increments the decode counter,
calls `onDecodeError`, and `return`s, so the offset commits, even when
`retryStrategy.kind === "retry-topics"` and a DLQ exists. Checked with
`gh api repos/loganbnielsen/sol-kafka/contents/src/retryable.ts --jq .content | base64 -d`.

The decision is made (HARDEN-004 handoff step 6, recorded in BUG-051); this is
implementation parity work, not a new question.

## Remediation

In `@sol-fab/kafka`: add `decodeErrorPolicy: "route-to-dlq" | "ack-and-drop"` to
the retryable options, defaulting to `route-to-dlq` under `retry-topics` and
refusing it under `in-memory`. Publish the raw record (value, key, headers) plus
`X-Sol-Decode-Error`/`X-Sol-Origin-Group` to `<source>.<group>.dlq` through the
existing relay, and throw on publish failure so the offset stays uncommitted.
Bump the dependency in `examples/pluto/app/demo_ts/fulfillment_worker`.

## Acceptance criteria

- Test in sol-kafka: under `retry-topics`, an undecodable record is published to
  the DLQ with raw payload, key, headers and the diagnostic before its offset
  commits; a failed publish leaves it uncommitted; `ack-and-drop` still skips.
- `demo_ts/fulfillment_worker` uses the new release.
