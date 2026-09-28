---
id: REFAC-146
type: refactor
severity: medium
title: Make retry-topic consumption a visible phase pipeline
source: Logan readability review generalized by style audit (2026-09-27)
---

Make retry-topic consumption a visible phase pipeline

**Depends on:** None.

**Premise verified (2026-09-27):** read the internal signature and complete implementation
on `origin/main` at `954afad7`; the 17-argument controller and duplicated record policy
remain.

**Problem:** `Kafka_service_retry_topics.consume` spans configuration validation,
topic naming and provisioning, producer effects, construction of two consumers,
decode/dispatch policy, relay-fiber lifecycle, logging, and final error arbitration in
one controller-sized closure
(`framework/ocaml/kafka-eio-service/lib/kafka_service_retry_topics.ml`). Its internal
signature carries 17 arguments, and the handler-error → action → execution → consumer
result flow is inlined separately for source and retry records. The phases are hard to
scan and the duplicated policy can drift.

## Remediation

Introduce one domain-named retry runtime/config input value, extract one shared
record-processing path, and leave `consume` as short linear orchestration across topic
provisioning, relay startup, source consumption, shutdown, and error reconciliation.
Keep effects explicit at those phase boundaries; do not add a generic controller
framework or a dependency.

## Acceptance criteria

- The internal consume call groups runtime inputs and has seven arguments rather than 17.
- Source and retry records share one tested handler-error/action execution path.
- Topic provisioning, relay start, source run, shutdown, and error reconciliation are
  visible sequential phases in the top-level function.
- Existing retry/DLQ semantics and tests remain unchanged, with one focused test proving
  that source and retry routes use the shared decision path.
- Demo/example: not applicable; the application-facing retry contract is unchanged.
- Language parity: no impact; this reorganizes the OCaml implementation without changing
  the cross-language retry/DLQ convention.

## Completion (2026-09-28)

- Count correction: `git show 954afad7:framework/ocaml/kafka-eio-service/lib/kafka_service_retry_topics.mli`
  shows 17 consume inputs, counting trailing unit and excluding arrows inside callbacks.
  The former 27 count included callback parameters. The corresponding dune
  `private_modules` declaration confirms this is an internal, not application-public API.

- Rechecked the premise after REFAC-148 merged: the retry controller still combined
  provisioning and consumer lifecycles and duplicated handler-error policy.
- A named retry runtime carries consumer callbacks, policy, and message handling;
  Eio switch/network/clock remain explicit environment inputs.
- `consume` now composes `prepare_topics`, `publish_relay`, and `run_consumers`.
  The lifecycle phase explicitly starts the retry relay, runs the source, reconciles
  relay failure, and closes the source. Its handlers remain local to that lifecycle:
  no generic controller/context or application-facing contract was added.
- Source and retry dispatch share `process_handler_result`. The new focused test
  checks source attempt 1, retry increment, retry exhaustion, unchanged dead-letter
  attempt, publish-before-ack, and no acknowledgement after failed publication.
- Validation: framework build, formatting, all 40 kafka-service unit tests, and six
  live broker integration tests covering partition errors, failed relay shutdown,
  source decode-to-DLQ, Ack-and-drop, and rejection of unsupported DLQ policy pass.
- Demo/example: not applicable; application-facing retry behavior is unchanged.
  No language-parity impact: retry/DLQ conventions are unchanged.
