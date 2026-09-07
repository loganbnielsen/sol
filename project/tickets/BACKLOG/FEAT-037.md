---
id: FEAT-037
type: feature
severity: low
source: architecture discussion 2026-09-07 following FEAT-033 — the same "protocol vs. policy" distinction FEAT-033's findings apply to Sol's own OCaml kafka-eio-service package, not just the TS port
---

**Depends on:** FEAT-034 in practice — the natural trigger for this ticket is FEAT-034 actually getting built, which would be the second real consumer needed to validate the boundary (see below). Not a hard code dependency.

Split `integrations/kafka/kafka-eio-service/` into a generic Confluent Schema Registry protocol client and Sol's opinionated policy layer — once there's a second real consumer of the protocol-only piece, not preemptively.

## Blocked on

**No second consumer exists yet.** This repo's own established practice — `kafka-eio`, `obs-eio`, and `pg-eio` were all extracted into standalone packages *after* real usage existed and proved where the boundary actually was, not designed upfront (the one documented exception, `aws-eio`, was a deliberate foundation-layer bet, not the default). Splitting `kafka-eio-service` now, with exactly one consumer (Sol's own OCaml services), would be exactly the kind of premature abstraction that practice argues against. Do not start this speculatively; wait for FEAT-034 (or any other real second consumer) to exist.

## The distinction this ticket is about

`kafka-eio` (standalone opam package) is already cleanly separated from `kafka-eio-service` (lives in this repo) — that split exists and is correct: `kafka-eio` is a pure Kafka protocol client (produce/consume, no opinions), `kafka-eio-service` is Sol's policy layer on top. This ticket is about a *second*, finer split hiding inside `kafka-eio-service` itself:

- **Protocol-generic, not Sol-specific:** `kafka_service_schema.ml`/`kafka_service_http.ml` implement the Confluent Schema Registry HTTP API — register a schema (`POST /subjects/{subject}/versions`), check compatibility (`POST /compatibility/subjects/{subject}/versions/latest`), set subject compatibility (`PUT /config/{subject}`), and the Confluent wire format (5-byte magic-byte + big-endian schema-ID header, `Confluent_wire` module). This is Confluent's public, documented protocol. Anyone using a Confluent-compatible registry (Redpanda's included) would implement the same calls regardless of what framework opinions sit on top. Nothing here is Sol-specific.
- **Sol's actual opinion, not generic:** `kafka_service.ml`'s `register` function (`kafka_service.ml:144-178`) composes those protocol calls in a specific order with specific fatality semantics — `register_schema` first and fatal, `set_subject_compatibility` second and non-fatal (logged as a warning). `kafka_service_retry_topics.ml` and `kafka_service_intf.ml`'s `wrap_on_decode_error` encode Sol's reject-vs-retry-vs-crash policy. Nobody else would necessarily make the same calls Sol did here — this is the part that's genuinely Sol's, not the protocol's.

FEAT-033 is direct evidence this distinction is real and not academic: building the TS port required re-deriving both halves independently by reading OCaml source, and got the *policy* half wrong twice (schema-registration call order/fatality, and the retry/crash routing) while getting the *protocol* half (Confluent wire format encode/decode) right on the first try with zero review findings against it. That's exactly the signature you'd expect if one half is well-specified public protocol and the other is unwritten-down internal policy.

## What "done" looks like, when this is picked up

1. Extract the protocol-generic pieces (schema registration, compatibility check/set, Confluent wire format) into their own package or clearly separated module boundary with its own `.mli` — decide standalone-opam-package vs. in-repo module split based on whether the second consumer (from FEAT-034 or elsewhere) is in-tree or genuinely external.
2. `kafka_service.ml`'s `register` orchestration and `kafka_service_retry_topics.ml` stay as Sol's policy layer, now visibly built *on* the protocol module rather than interleaved with it.
3. Before implementing the protocol-generic piece from scratch again: check whether a generic OCaml Confluent-Schema-Registry client already exists in the opam ecosystem, and separately whether the TS side of FEAT-034 found or should use an existing generic npm equivalent — if one exists on either side, that's evidence for what the OCaml module's actual public shape should be, not just an implementation detail to match.

## Non-goals

- Not a rewrite of `kafka_service.ml`'s actual behavior — same registration order, same fatality semantics, same retry/crash routing. This is a module-boundary change, not a policy change.
- Not blocking or gating FEAT-034 — FEAT-034 can and should proceed (when its own gate clears) using `kafka_service_schema.ml` as a reference to port from, whether or not this split has happened yet.
