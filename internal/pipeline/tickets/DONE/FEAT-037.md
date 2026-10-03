---
id: FEAT-037
type: feature
severity: low
source: architecture discussion 2026-09-07 following FEAT-033 — the same "protocol vs. policy" distinction FEAT-033's findings apply to Sol's own OCaml kafka-eio-service package, not just the TS port
---

**Depends on:** FEAT-034 in practice — the natural trigger for this ticket is FEAT-034 actually getting built, which would be the second real consumer needed to validate the boundary (see below). Not a hard code dependency.

Split `framework/kafka-eio-service/` into a generic Confluent Schema Registry protocol client and Sol's opinionated policy layer — once there's a second real consumer of the protocol-only piece, not preemptively.

## Status — premise refreshed 2026-09-15

**The stated trigger has fired: a second real consumer now exists.** This
ticket was blocked on "wait for FEAT-034 (or any other real second
consumer) to exist." FEAT-034's `@sol/kafka` was built, merged and
dogfooded (FEAT-038) — and its two adversarial-review rounds are exactly
the evidence this ticket cites for the protocol/policy split: the Confluent
wire format (protocol half) ported correctly first try, while the
registration order/fatality and retry/crash routing (policy half) were
wrong twice.

The original rationale — "exactly one consumer, do not preemptively
abstract" — was about the OCaml side alone. `@sol/kafka` is an independent
*re-derivation* rather than a consumer of the OCaml module, so it does not
literally call `kafka_service.ml`; but it is independent evidence of where
the boundary is, which is what the ticket was waiting for.

**This is not a promotion.** A blocking premise disappearing is not the
same as "build this now": the split still competes for priority against
everything else, and this ticket stays in `BACKLOG` until someone
consciously prioritises it. Treat "belongs/actionable" and "should be done
next" as separate decisions. What this section removes is only the *false*
claim that the work cannot be scoped yet.

## Correction (2026-10-02)

The *goal* — a protocol/policy module boundary — still stands, but the policy
half's description below is stale, and the boundary this ticket draws is now
partly different from the one it was written against:

- `kafka_service.ml`'s `register` no longer composes the schema-registry calls
  "`register_schema` first and fatal, `set_subject_compatibility` second and
  non-fatal". BUG-105 moved registration into a deployment step, and
  `Kafka_service_schema.register_contract` (`kafka_service_schema.ml:143-149`)
  sets `FULL` compatibility **first** and treats **either** failure as fatal.
  The wrong-way-round description is corrected in place below.
- `kafka_service_retry_topics.ml` no longer exists: FEAT-113 removed
  message-level retry and the relay. The retry/crash policy this ticket cites as
  the policy half is now the `Ack | Fail` stop contract in `worker.ml` plus
  `Kafka_service_dlq`. Any split must be drawn against that, not the retry-topic
  module.
- The TypeScript re-derivation is now four published packages, and the
  behavioural-parity inventory is `2026-10-02_cross_language_contract_audit.md`.
  That audit found the schema-registration ordering still diverges between the
  two languages (FEAT-119 owns the registration lifecycle), which is the same
  "the policy half is unwritten-down" evidence this ticket was built on.

Corrected by the cross-language contract audit
(`2026-10-02_cross_language_contract_audit.md` § 6).

## The distinction this ticket is about

`kafka-eio` (standalone opam package) is already cleanly separated from `kafka-eio-service` (lives in this repo) — that split exists and is correct: `kafka-eio` is a pure Kafka protocol client (produce/consume, no opinions), `kafka-eio-service` is Sol's policy layer on top. This ticket is about a *second*, finer split hiding inside `kafka-eio-service` itself:

- **Protocol-generic, not Sol-specific:** `kafka_service_schema.ml`/`kafka_service_http.ml` implement the Confluent Schema Registry HTTP API — register a schema (`POST /subjects/{subject}/versions`), check compatibility (`POST /compatibility/subjects/{subject}/versions/latest`), set subject compatibility (`PUT /config/{subject}`), and the Confluent wire format (5-byte magic-byte + big-endian schema-ID header, `Confluent_wire` module). This is Confluent's public, documented protocol. Anyone using a Confluent-compatible registry (Redpanda's included) would implement the same calls regardless of what framework opinions sit on top. Nothing here is Sol-specific.
- **Sol's actual opinion, not generic (corrected 2026-10-02):** `Kafka_service_schema.register_contract` (`kafka_service_schema.ml:143-149`) composes those protocol calls in a specific order with specific fatality semantics — `set_subject_compatibility` (`FULL`) **first** and fatal, `register_schema` **second** and fatal. `worker.ml`'s `Ack | Fail` stop contract, `kafka_service_dlq.ml` and `kafka_service_intf.ml`'s `wrap_on_decode_error` encode Sol's reject-vs-stop-vs-crash policy. Nobody else would necessarily make the same calls Sol did here — this is the part that's genuinely Sol's, not the protocol's.

FEAT-033 is direct evidence this distinction is real and not academic: building the TS port required re-deriving both halves independently by reading OCaml source, and got the *policy* half wrong twice (schema-registration call order/fatality, and the retry/crash routing) while getting the *protocol* half (Confluent wire format encode/decode) right on the first try with zero review findings against it. That's exactly the signature you'd expect if one half is well-specified public protocol and the other is unwritten-down internal policy.

## What "done" looks like, when this is picked up

1. Extract the protocol-generic pieces (schema registration, compatibility check/set, Confluent wire format) into their own package or clearly separated module boundary with its own `.mli` — decide standalone-opam-package vs. in-repo module split based on whether the second consumer (from FEAT-034 or elsewhere) is in-tree or genuinely external.
2. `Kafka_service_schema.register_contract`'s orchestration and `kafka_service_dlq.ml` stay as Sol's policy layer, now visibly built *on* the protocol module rather than interleaved with it.
3. Before implementing the protocol-generic piece from scratch again: check whether a generic OCaml Confluent-Schema-Registry client already exists in the opam ecosystem, and separately whether the TS side of FEAT-034 found or should use an existing generic npm equivalent — if one exists on either side, that's evidence for what the OCaml module's actual public shape should be, not just an implementation detail to match. (FEAT-034 shipped without this check, because this ticket was blocked at the time; close that loop explicitly rather than assuming it was done.)

## Non-goals

- Not a rewrite of the registration/schema behavior — same ordering (compatibility first), same fatality semantics (both fatal), and the same `Ack | Fail`/DLQ policy. This is a module-boundary change, not a policy change.
- Not blocking or gating FEAT-034 — it has since shipped (`@sol/kafka` ported from `kafka_service_schema.ml` as a reference) without this split having happened, exactly as intended.

## Disposition (2026-10-03) — actionable pre-alpha

Premise re-checked against current `origin/main`; the work is still real.
Evidence: the protocol/policy boundary is unchanged; the ticket's 2026-10-02 correction refreshes the policy half (`register_contract` order/fatality, `Ack | Fail`, `Kafka_service_dlq`).

Promoted to `READY_FOR_ENGINEERING/` by the pre-alpha BACKLOG adjudication
(`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`).

## Completion notes (2026-10-03)

- **Premise verified.** On `origin/main @ 1f2e5f05`, `kafka_service_schema.ml` still held
  the Confluent Schema Registry HTTP calls interleaved with `register_contract` and
  `decode_message`; the protocol/policy boundary did not exist as a module.
- **Decision — in-repo module boundary, not a standalone opam package.** The ticket's test
  (in-tree consumer ⇒ module, external consumer ⇒ package) resolves to the module: the only
  consumer is `kafka_service.ml` in this package, and the "second consumer" evidence
  (`@sol/kafka`) is an independent re-derivation that does not call this module. Step 3's
  ecosystem check found no generic OCaml Confluent Schema Registry client: `opam search
  confluent` returns only `kafka-eio-service` itself, and `opam search schema` returns
  Avro/JSON-schema libraries, none Confluent. No external consumer justifies a package
  today; the boundary is reversible if one appears, which is why the in-tree split was the
  conservative choice.
- **Landed.** New private `confluent_registry.ml`/`.mli` holds the protocol-generic half:
  `subject_name`, `is_subject_not_found`, the compatibility/registration response decoders,
  `check_compatibility` (returning a typed `Compatible | Incompatible | No_schema_registered`
  verdict), `set_subject_compatibility`, `register_schema`, `lookup_schema`, and
  `module Wire` (the 5-byte Confluent framing). `kafka_service_schema.ml`/`.mli` is now Sol's
  policy half built on it: `Schema.check` maps the protocol verdict to the compatibility
  message, `Schema.check_all`, `register_contract` (FULL-compatibility first, both fatal),
  and `decode_message`. `kafka_service.ml` re-exports the protocol pieces from
  `Confluent_registry`; the public `Kafka_service` API is unchanged. The package spec's
  *Package Structure* section is corrected to match.
- **Behaviour preserved.** No ordering, fatality, error-string or wire-format change:
  `dune build` (full project) green; `dune test framework/ocaml/kafka-eio-service/test/`
  → 28 tests pass; `dune fmt` clean.
- **Demo/example.** Not applicable — a private module boundary; the public
  `kafka-eio-service` API and every example call site are unchanged.
- **Language parity (DEC-022).** No application-facing contract change. The TS side
  consumes the same registry protocol and wire format but does not call this OCaml module,
  so the split neither helps nor blocks it; step 3's npm-side question belongs to the TS
  package and is not resolved here.
