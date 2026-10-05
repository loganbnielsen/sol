---
id: CODEX_STYLE_AUDIT-088
type: bug
severity: medium
title: "Validate Kafka admin partition metadata before making durability claims"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Validate Kafka admin partition metadata before making durability claims

**Depends on:** None.

**Principles:** 1, 2, 7, 21–23, 29, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `framework/ocaml/kafka-eio-service/lib/kafka_service_intf.ml:98`: decode_topic_partitions counts replicas without decoding their entries and counts partition rows without validating identities.
- `:106`: expected malformed-input rejection uses raise Exit inside List.map.
- `framework/ocaml/kafka-eio-service/lib/kafka_service.ml:263`: decoded counts feed the partition/durability guard.
- `framework/ocaml/kafka-eio-service/test/test_kafka_service.ml:507`: existing tests cover valid metadata, missing replicas, empty response, and malformed JSON, but not fabricated replica entries or duplicate identities.

## Mechanism and impact

A response such as `[{"replicas":[null,null,null]}]` is accepted as one partition with replication factor three. Malformed evidence can therefore satisfy Single_broker_loss. Duplicate entries can inflate counts. These are external values becoming authoritative typed claims before validation.

## Remediation

Decode the actual supported admin response into validated partition/replica records using Results. Derive counts only from validated unique identities, and preserve the original body in malformed-response errors. Verify the actual supported Redpanda response shape during implementation; existing unit fixtures alone are not schema authority. Catch JSON syntax exceptions without exception-driven structural control flow.

## Acceptance criteria

- Representative supported response retains expected partition and replication values.
- Null/non-object entries, missing/invalid required identity fields, and duplicate partition/replica identities fail closed.
- Invalid evidence cannot satisfy the durability guard.
- Malformed errors retain their response body; no Exit parser control flow remains.

- Demo/example: update a runnable contract/durability example if the supported public metadata contract changes; otherwise record internal adapter validation only.
- Language parity: record whether the TypeScript admin adapter enforces equivalent evidence validation; use a concrete tracking reference for any gap.

## Existing work and scope

BUG-099 implemented the original replication guard; this ticket addresses validation of its evidence. REFAC-133 is a completed error-handling precedent, not an open duplicate.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
