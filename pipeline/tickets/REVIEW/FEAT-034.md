---
id: FEAT-034
type: feature
severity: medium
source: FEAT-033 findings (project/dogfood/2026-09-07_typescript_demo_spike.md) — headline recommendation of that spike
branch: FEAT-034/sol-kafka
worktree: ../sol-FEAT-034-sol-kafka
pr: https://github.com/loganbnielsen/sol/pull/165
---

**Depends on:** FEAT-033 (done — merged as the evidence base for this ticket).

Build `@sol/kafka`, a TypeScript package encoding Sol's Kafka *policy* layer — not a new Kafka client, a thin layer of Sol-specific conventions on top of `kafkajs` — once a real external TypeScript user actually needs it.

## Unblocked (2026-09-08)

Originally gated on real external TS demand (see history below) — the user has decided to unblock this now regardless, since `@sol/kafka`/`@sol/obs` are what the `examples/pluto/app/demo_ts/` TS demo (FEAT-033) will be used to show off the framework going forward, not something to wait on organic adoption for. Moved to `READY_FOR_ENGINEERING`.

**Original blocking rationale (superseded, kept for context):** No real external TS user had hit the OCaml wall yet. This ticket captured scope so it was ready to pick up the moment that happened. See [[project_ocaml_only_risk]]: the decision was to validate demand before building any `@sol/*` package, and FEAT-033 was the evidence-gathering step, not permission to proceed.

## Why this, specifically (not a general "TS SDK" ticket)

`kafkajs` already solves the Kafka *protocol* problem — produce/consume, consumer groups, admin. Everything below is Sol's own *policy* on top of that protocol, currently expressed only as OCaml source in `integrations/kafka/kafka-eio-service/lib/`, invisible to anyone not reading it. FEAT-033 proved this isn't hypothetical: building a TS port by hand, using idiomatic ecosystem libraries throughout, still produced real bugs in exactly this category — two independent adversarial review rounds found issues here that a single self-review missed, which is itself evidence this knowledge doesn't transfer by "just writing idiomatic TypeScript."

**Scope, derived directly from FEAT-033's capability table and bug findings:**

1. **Schema registry protocol + Sol's specific call-order/fatality policy.** The protocol itself (register a schema, check compatibility, Confluent wire format) is generic — see FEAT-037 below on whether to reuse/extract a generic client instead of hand-rolling it again. What's Sol-specific and must be preserved exactly: `Kafka_service.register` (`integrations/kafka/kafka-eio-service/lib/kafka_service.ml:144-178`) calls `register_schema` FIRST and treats its failure as **fatal**, then `set_subject_compatibility` SECOND and treats its failure as **non-fatal** (logged as a warning, startup continues). FEAT-033's TS port got this backwards on the first draft — compatibility-check-then-register, both fatal — and only round-1 adversarial review caught it by reading `kafka_service.ml` line by line. This ordering/fatality split needs to be documented as a first-class API decision in `@sol/kafka`, not an implementation detail someone can get wrong.
2. **Explicit topic provisioning.** `Kafka_service.register` also calls `ensure_topic` (`kafka_service_intf.ml:54`, wrapping `Kafka.Producer.create_topic` with an explicit partition count — default 1, from `kafka_service_config.ml:16` — and `replication_factor:1`) *before* touching the schema registry. FEAT-033's TS port initially skipped this entirely and relied on broker auto-create-on-produce, which is invisible in local dev (Redpanda has it on by default) but fails hard (`UNKNOWN_TOPIC_OR_PARTITION`) on any production cluster with `auto.create.topics.enable=false`. This has to be an explicit `admin().createTopics(...)` call in `@sol/kafka`, not left to the broker's defaults.
3. **Confluent wire format** (5-byte magic-byte + big-endian schema-ID header prepended to every message). Straightforward to port correctly — FEAT-033's port matched the OCaml reference (`kafka_service_schema.ml`'s `Confluent_wire` module) byte-for-byte and no review round found an issue here. Low risk, but still needs a canonical implementation so every TS service doesn't reimplement it slightly differently.
4. **Retry/reject/crash routing.** A message that fails to decode/validate should be rejected, not retried (it will never become valid) — this is `kafka_service_intf.ml`'s `wrap_on_decode_error`, which counts decode failures on their own metric (`sol_worker_decode_errors_total`) and never routes them through the handler at all. A downstream failure (e.g. Postgres) on an otherwise-valid message should be retried. A consumer that has exhausted `kafkajs`'s own internal retry/self-heal (check `payload.restart` on the `CRASH` event, not an unconditional exit) should crash loudly so k8s restarts it. FEAT-033 got this wrong **twice**, once per adversarial review round: first conflating decode/DB failures under one label and swallowing both, then over-aggressively exiting on every crash including ones `kafkajs` was already self-healing from. This is the single clearest piece of evidence in the whole spike that this policy is genuinely hard to reconstruct by hand — it is worth encoding once, correctly, rather than trusting every future TS author to rediscover both failure modes.
5. **W3C `traceparent` propagation onto/from a Kafka message.** OpenTelemetry has no official carrier for Kafka (unlike HTTP/gRPC) — this glue has to exist somewhere. FEAT-033's port got the span-linkage right but the flags byte wrong twice: the producer hardcoded `"01"` regardless of actual sampled state, and the consumer's parser used `parseInt(flags, 16) || 1`, which incorrectly treats a legitimate unsampled trace (`flags=0`) as sampled due to JS falsy-zero coercion. `@sol/kafka` (or `@sol/obs`, see FEAT-035 — this specific piece could live in either, decide at build time) should own this so it's correct once.

## Non-goals

- Not a general-purpose Kafka framework — only the Sol-specific policy layer above. `kafkajs` remains the transport; don't wrap or hide it.
- Not a reimplementation from scratch of the Confluent Schema Registry HTTP client if FEAT-037 (or a pre-existing generic npm package) already provides one by the time this is picked up — check first.
- Not `@sol/http`/`@sol/worker` (FEAT-036) or `@sol/obs` (FEAT-035) — this ticket is Kafka-specific policy only, though it will likely depend on `@sol/obs` for the tracing/metrics primitives it uses.
