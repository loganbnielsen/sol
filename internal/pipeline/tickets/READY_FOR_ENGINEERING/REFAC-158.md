---
id: REFAC-158
type: refactor
severity: low
source: "code-layer audit theme applied to the pinned support libraries, 2026-09-29 (merge: a boundary that only delegates, and duplicate declarations)"
title: Stop hand-copying public signatures in the kafka-eio and aws-eio facades
---

Stop hand-copying public signatures in the kafka-eio and aws-eio facades

**Depends on:** None.

## Problem

Both `*-eio` facades hand-write the signatures of the private modules they
re-export, so every public declaration exists twice and a change has to be made
in both places:

- `kafka-eio/lib/kafka.mli` is 420 lines of `module Error/Security/Topic_name/
  Consumer/Producer : sig … end`, while `kafka-eio/lib/kafka.ml` binds them with
  `module Consumer = Kafka_consumer` and friends over `private_modules`
  (`lib/dune`). The real interfaces live in `kafka_consumer.mli` (245 lines) and
  its siblings, which are not visible to callers.
- `aws-eio/lib/aws.mli` has the same shape: `module Error/Sigv4/Http/Credentials :
  sig … end` over `module X = Aws_x` (`aws.mli:7,21,84,169`; `aws.ml:1-4`).

This is not theoretical. Applying REFAC-155 to kafka-eio's consumer callbacks
required editing the same four signatures in `kafka_consumer.mli` *and*
`kafka.mli` by hand, and the second file is where a missed edit becomes an
inconsistency that only the compiler catches when the two disagree.

A naive `module Consumer : module type of Kafka_consumer` is not enough: the
facade deliberately hides exactly three internals — `Consumer.handle`,
`Consumer.stream`, and `Producer.consumer_handle` (+ its type) — so widening the
facade to the real interface would expose them.

## Remediation

In each repository, hide the internals at their source rather than in a copy of
the interface, then delegate the signature:

1. Move the members the public module should not expose into an internal
   submodule (or a separate private module), so `Kafka_consumer.mli` *is* the
   public surface and `Producer`'s wrapper keeps only its own extra
   `with_transaction`.
2. Replace each hand-written block with `module Consumer : module type of
   Kafka_consumer` (and likewise `Error`, `Security`, `Topic_name`, `Producer`,
   `Http`, `Sigv4`, `Credentials`).
3. Update the internal callers of the moved members — `kafka.ml`'s
   `with_transaction` uses `Kafka_consumer.handle` today.
4. Keep `(* … *)` documentation comments where they carry the reasoning the
   facade currently holds.

## Acceptance criteria

- Neither facade declares a `val`/`type` list of its own for the modules it
  re-exports; the exposed signature is the module's own `.mli`.
- The three kafka internals stay invisible to callers, and this is enforced by
  the build rather than by a hand-maintained list (an internal module that is a
  `private_module`, or an unexported type).
- No public signature a caller can observe changes; if one does, it is listed in
  the completion notes with the call sites updated.
- Each repository's CI is green on its own PR. Demo/example: not applicable
  (package-internal shape). Language parity: no impact.
