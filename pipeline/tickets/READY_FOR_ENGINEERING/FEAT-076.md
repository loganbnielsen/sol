---
id: FEAT-076
type: feature
severity: medium
source: messaging-substrate discussion 2026-09-14 (Kafka vs SQS/RabbitMQ/Pulsar for Sol worker semantics)
---

**Depends on:** None.

**Related:** DEC-021, FEAT-077.

Add first-class `Ack | Retry | Dead_letter` handling to `sol-worker` /
`kafka-eio-service`, so a poison message no longer blocks progress on the
rest of its partition, and retry/DLQ behavior stops being something every
app author reinvents by hand.

## Design

- Kafka remains the only messaging substrate — no new broker, no pluggable
  backend.
- Implement via retry and DLQ topics: Sol owns provisioning/naming
  conventions (e.g. `<topic>.retry`, `<topic>.dlq`) rather than leaving them
  to each app.
- Handler return type becomes explicit:
  ```ocaml
  type outcome =
    | Ack
    | Retry of Duration.t
    | Dead_letter of string
  ```
- Document the ordering and duplicate-delivery implications of
  diverting/reinjecting through retry topics — this is an emulation of
  queue semantics on top of a log, not equivalent to a native queue, and
  callers need to know that up front rather than discover it.

## Non-goals

- No SQS/RabbitMQ/ElasticMQ/Pulsar abstraction.
- No generic pluggable messaging-backend configuration.

## Acceptance criteria

- `sol-worker` handlers can return `Ack | Retry | Dead_letter` and the
  framework provisions/routes the corresponding retry/DLQ topics.
- A poison message does not block unrelated messages from being
  retried/progressing.
- Ordering and duplicate-delivery tradeoffs are documented in the
  `sol-worker`/`kafka-eio-service` spec doc.
- Demo/example coverage per repo convention: update `examples/local-demo`
  (or state why not applicable) to show retry/DLQ usage.
