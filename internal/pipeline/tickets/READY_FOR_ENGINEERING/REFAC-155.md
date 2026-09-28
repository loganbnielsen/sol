---
id: REFAC-155
type: refactor
severity: low
title: Group the consumer lifecycle and retry callbacks behind one hooks value
source: Logan code review (2026-09-28), generalized from kafka_service consume_partitioned
---

Group the consumer lifecycle and retry callbacks behind one hooks value

**Depends on:** None.

**Premise verified (2026-09-28):** `Kafka_service.consume` takes four `?on_*`
callbacks; `consume_partitioned` takes six plus `?ot` and `?decode_error_policy`.
`Kafka_service_retry_topics.runtime` already groups the same callbacks internally,
so the public signature is the un-grouped copy of a concept the implementation
already treats as one value.

## The principle — a cross-cutting callback family is one concept

When several optional/defaulted arguments are all instrumentation or lifecycle
hooks of the same concern, group them behind one named record with a `no_hooks`
default, so the core signature stays about the operation. This is the third mode
alongside "few independent inputs stay labels" and "one real concept becomes a
record": a family of optional callbacks is one concept. Do not bundle unrelated
required dependencies into the same record merely to shorten the signature.

## Remediation

- Define `Kafka_service_intf.consumer_hooks` (`on_ready`, `on_assigned`,
  `on_revoked`, `on_poll`, `on_retry`, `on_relay_publish`) plus `no_hooks`.
- Replace the individual callback arguments on `Kafka_service.consume` and
  `Kafka_service.consume_partitioned` with `?hooks`, re-exported from
  `Kafka_service` the way `consume_partitioned_error` already is.
- Keep `?ot`, `?on_decode_error` / `?decode_error_policy` and `~retry_strategy`
  separate: a handle and policies are not callbacks.
- Reuse `consumer_hooks` inside `Kafka_service_retry_topics.runtime` instead of
  repeating its six fields.
- Record the rule in `internal/pipeline/audits/STYLE_AUDIT.md`.

## Acceptance criteria

- `consume` and `consume_partitioned` take one `?hooks` value; no `?on_*`
  callback argument remains on either.
- `worker.ml` builds each hooks value once and passes it; its app-facing
  `?on_ready` is unchanged.
- `no_hooks` reproduces today's defaults exactly; behavior and output unchanged.
- Existing kafka-service integration tests pass, and `kafka-eio-service.md`
  matches the new signatures.
- Demo/example: no app-author surface changes (`Worker` keeps `?on_ready`); no
  example calls these functions directly. Record the exemption.
- Language parity: no impact; this is an OCaml framework-internal signature, and
  the TypeScript worker uses its own Node Kafka client.
