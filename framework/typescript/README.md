# TypeScript framework

TypeScript is a first-class Sol application language (DEC-022). Its framework
packages live in their own public repositories and are consumed from npm, the
same extraction pattern as the OCaml `*-eio` packages. This directory exists so
the language is visible in `framework/`; it holds no implementation.

| Package | Repository | What it supplies |
| --- | --- | --- |
| `@sol-fab/kafka` | [`loganbnielsen/sol-kafka`](https://github.com/loganbnielsen/sol-kafka) | Kafka policy over `kafkajs`: schema-registry ordering, topic provisioning, the Confluent wire format, retry/DLQ routing, trace propagation |
| `@sol-fab/obs` | [`loganbnielsen/sol-obs`](https://github.com/loganbnielsen/sol-obs) | Metric names, label vocabularies, the Loki push shape, W3C `traceparent` propagation |
| `@sol-fab/svc` | [`loganbnielsen/sol-typescript`](https://github.com/loganbnielsen/sol-typescript) | The `-svc` lifecycle: bounded drain and idempotent `SIGTERM`/`SIGINT` handling |
| `@sol-fab/worker` | [`loganbnielsen/sol-typescript`](https://github.com/loganbnielsen/sol-typescript) | The `-worker` lifecycle, for a unit with no request boundary |

All four are Apache-2.0 and published with build provenance.

## Start here

- **Runnable example:** [`examples/pluto/app/demo_ts`](../../examples/pluto/app/demo_ts/README.md),
  a TypeScript `-svc` and `-worker` pair deployed alongside pluto's OCaml units.
- **What every Sol app must do, in any language:** the
  [application contract](../../docs/reference/README.md).
- **What TypeScript can and can't do today:** the
  [compatibility matrix](../../docs/deployment/compatibility.md). TypeScript is
  staged behind the production profile until its parity triggers are met
  (DEC-026 §2).
