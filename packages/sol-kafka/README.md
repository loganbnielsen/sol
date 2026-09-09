# @sol/kafka

Sol's Kafka **policy** layer on top of [`kafkajs`](https://kafka.js.org/) — not a new Kafka client. `kafkajs` remains the transport; this package owns the Sol-specific conventions a TypeScript service needs to interoperate correctly with Sol's OCaml services on the same topics.

Encodes five conventions that [FEAT-033](../../pipeline/tickets/DONE/FEAT-033.md)'s hand-rolled TypeScript port of `examples/local-demo` got wrong at least once each, evidenced by two independent adversarial review rounds:

1. **Schema registration ordering/fatality** (`registerTopic`) — register the schema first (fatal on failure), then set subject compatibility second (non-fatal, logged as a warning). Matches `framework/kafka-eio-service/lib/kafka_service.ml`'s `register` exactly.
2. **Explicit topic provisioning** (`registerTopic`) — provisions the topic via `admin().createTopics()` *before* touching the schema registry, rather than relying on broker auto-create (invisible in local dev, fails hard in production with `auto.create.topics.enable=false`).
3. **Confluent wire format** (`encodeWire`/`decodeWire`) — the 5-byte header (magic byte + big-endian schema ID), byte-for-byte compatible with `kafka_service_schema.ml`'s `Confluent_wire`.
4. **Decode/retry/crash routing** (`wrapEachMessage`/`wireCrashListener`) — a decode/validation failure is a rejection (counted, never retried, handler never runs); a downstream handler failure (e.g. a DB error) is retried by `kafkajs`; the process only exits when `kafkajs` itself has given up (`payload.restart === false`), not on every crash it was already self-healing from.
5. **W3C `traceparent` propagation** (`traceparentOf`/`extractTraceparent`) — OpenTelemetry has no official Kafka carrier, so this glue has to exist somewhere; correctly preserves an unsampled trace's flags byte (`0`) instead of coercing it to "sampled" via JS falsy-zero coercion.

## Non-goals

- Not a general-purpose Kafka framework. `kafkajs` remains the transport — this package never wraps or hides it.
- Not a reimplementation of the Confluent Schema Registry HTTP client beyond what Sol's own policy needs.
- `traceparentOf`/`extractTraceparent` live here temporarily. `@sol/obs` (FEAT-035) is the intended long-term home for general tracing/metrics primitives — move these there once it exists, rather than duplicating the logic.

## Usage

```ts
import { Kafka } from "kafkajs";
import { registerTopic, encodeWire, wrapEachMessage, wireCrashListener, traceparentOf } from "@sol/kafka";

const kafka = new Kafka({ clientId: "order-svc", brokers: ["localhost:9092"] });

const { schemaId } = await registerTopic({
  kafka,
  registryUrl: "http://localhost:8081",
  topicName: "orders",
  schema: JSON.stringify({ type: "object", properties: { /* ... */ } }),
});

// producer
const wire = encodeWire(schemaId, message);
await producer.send({ topic: "orders", messages: [{ value: wire, headers: { traceparent: traceparentOf(span) } }] });

// consumer
const decodeErrorsTotal = /* your Prometheus counter */;
await consumer.run({
  eachMessage: wrapEachMessage({
    decode: (json) => validateOrder(json), // throw to reject
    decodeErrorCounter: decodeErrorsTotal,
    handler: async ({ message, traceContext }) => { /* ... */ },
  }),
});
wireCrashListener(consumer);
```

## Status

Built in-tree (not yet extracted to a standalone publishable package) — same pattern this repo used for `kafka-eio`/`obs-eio`/`pg-eio`: build where a real consumer needs it first, extract once the boundary is proven. The current consumer is `examples/pluto/app/demo_ts/`.
