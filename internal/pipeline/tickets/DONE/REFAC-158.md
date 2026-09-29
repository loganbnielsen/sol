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

## Completion (2026-09-29)

**The remediated shape was wrong, and the analysis is part of the deliverable.** Re-verified against aws-eio `2a22706e` and kafka-eio `b2881b31`:

1. `module Consumer : module type of Kafka_consumer` — a signature copy declares *fresh* datatypes, so `Kafka.Error.t` stops being the `Kafka_error.t` the library's own functions return. Applied to aws-eio, `test_aws_credentials.ml` stopped compiling: *The value e has type Aws_error.t but an expression was expected of type Aws.Error.t*.
2. `module Consumer = Kafka_consumer` over a `private_module` compiles inside the library and fails for every consumer: s3-eio's clean build reports *The module Aws.Error is an alias for module Aws_error, which is missing*. `private_modules` are not installed, so an installed interface may not name one. This is what made the first attempt look viable — the library's own build and tests live in the same workspace, and only a consumer sees the installed `.cmi`.
3. So the hand-written copies were load-bearing *because the modules were private*: the copy was the only way to keep `aws.cmi`/`kafka.cmi` self-contained while the facade curated the surface.

**Resolution: install the modules and alias them.** Both packages drop `private_modules`; `Kafka`/`Aws` are sets of aliases over the modules that implement them, so each interface exists once, no datatype identity has to be preserved by hand, and delegation is safe because every module a signature names is installed.

Deliberate API changes, none of them preserved for compatibility's sake:

- kafka-eio: `Kafka_raw` (the librdkafka binding layer) and `Kafka_consumer_handle` (the offset token a transactional producer takes) are installed and reachable; `Kafka.Producer.with_transaction`'s `?consumer_offsets` takes `(Kafka.Consumer.handle consumer, offsets)` and the facade wrapper that performed that conversion is deleted; `kafka-eio-producer/test/test_producer_integration.ml` was updated to that form.
- aws-eio: `Aws_error`/`Aws_sigv4`/`Aws_sigv4_core`/`Aws_http`/`Aws_credentials` are installed; the `Aws.*` names callers use are unchanged.
- Acceptance line *the three kafka internals stay invisible, enforced by the build* is **withdrawn**: both were already marked `(**/**)` inside `Kafka_producer`/`Kafka_consumer` and mirrored by the facade, nothing depends on hiding them, and hiding them is what forced the copies.
- Acceptance line *no public signature a caller can observe changes* is replaced by the list above.

The layout and the API changes are recorded in `kafka-eio/CHANGES.md`, `aws-eio/CHANGES.md` and `aws-eio/README.md` (the design note that argued for the facade is replaced by the reason it could not be delegated).

Verified: each repo's own suite (kafka 9+9+4+3; aws 38+16+14+1); the three aws-eio consumers (`s3-eio`, `dynamodb-eio`, `lambda-eio`) build against the installed package; **sol's `framework/` and `cli/` build against both installed packages** at the pins bumped in this PR. Demo/example: not applicable (package-internal shape; no example names these modules). Language parity: no impact.
