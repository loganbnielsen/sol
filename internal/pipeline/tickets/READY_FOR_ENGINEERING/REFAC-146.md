---
id: REFAC-146
type: refactor
severity: medium
title: Make retry-topic consumption a visible phase pipeline
source: Logan readability review generalized by style audit (2026-09-27)
---

Make retry-topic consumption a visible phase pipeline

**Depends on:** None.

**Premise verified (2026-09-27):** read the public signature and complete implementation
on `origin/main` at `954afad7`; the 27-argument controller and duplicated record policy
remain.

**Problem:** `Kafka_service_retry_topics.consume` spans configuration validation,
topic naming and provisioning, producer effects, construction of two consumers,
decode/dispatch policy, relay-fiber lifecycle, logging, and final error arbitration in
one controller-sized closure
(`framework/ocaml/kafka-eio-service/lib/kafka_service_retry_topics.ml`). Its public
signature carries 27 arguments, and the handler-error → action → execution → consumer
result flow is inlined separately for source and retry records. The phases are hard to
scan and the duplicated policy can drift.

## Remediation

Introduce one domain-named retry runtime/config input value, extract one shared
record-processing path, and leave `consume` as short linear orchestration across topic
provisioning, relay startup, source consumption, shutdown, and error reconciliation.
Keep effects explicit at those phase boundaries; do not add a generic controller
framework or a dependency.

## Acceptance criteria

- The public/internal consume call no longer has a 27-argument signature.
- Source and retry records share one tested handler-error/action execution path.
- Topic provisioning, relay start, source run, shutdown, and error reconciliation are
  visible sequential phases in the top-level function.
- Existing retry/DLQ semantics and tests remain unchanged, with one focused test proving
  that source and retry routes use the shared decision path.
- Demo/example: not applicable; the application-facing retry contract is unchanged.
- Language parity: no impact; this reorganizes the OCaml implementation without changing
  the cross-language retry/DLQ convention.
