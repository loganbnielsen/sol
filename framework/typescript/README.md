# TypeScript framework

TypeScript is a first-class Sol application language (DEC-022). Its framework
packages live in their own public repositories and are consumed from npm, the
same extraction pattern as the OCaml `*-eio` packages. This directory exists so
the language is visible in `framework/`; it holds no implementation.

| Package | Repository | What it supplies |
| --- | --- | --- |
| `@sol-fab/kafka` | [`loganbnielsen/sol-kafka`](https://github.com/loganbnielsen/sol-kafka) | Kafka policy over `kafkajs`: schema-registry ordering, topic provisioning, the Confluent wire format, retry/DLQ routing, trace propagation |
| `@sol-fab/obs` | [`loganbnielsen/sol-obs`](https://github.com/loganbnielsen/sol-obs) | Metric names, label vocabularies, the Loki push shape, W3C `traceparent` propagation |
| `@sol-fab/svc` | [`sol-fab/sol-typescript`](https://github.com/sol-fab/sol-typescript) | The `-svc` lifecycle (bounded drain, idempotent `SIGTERM`/`SIGINT`), typed peer-call helpers for the declared `calls` graph, and DEC-063 workload-identity verification for callees |
| `@sol-fab/worker` | [`sol-fab/sol-typescript`](https://github.com/sol-fab/sol-typescript) | The `-worker` lifecycle, for a unit with no request boundary |
| `@sol-fab/retry` | [`sol-fab/sol-typescript`](https://github.com/sol-fab/sol-typescript) | The operation-level retry helper: one bounded, jittered policy vocabulary that retries a dependency call in place (mirrors the OCaml `sol-retry`; `@sol-fab/jobs` consumes the same vocabulary) |

All are Apache-2.0 and published with build provenance.

Sol-to-Sol calls use the same DEC-063 contract in both languages. Generated
bindings receive a typed peer per declared `call`, and `peerHeaders` attaches the
callee's projected ServiceAccount token as `Authorization: Bearer`. A
`@sol-fab/svc` callee authenticates those callers by default
(`createWorkloadIdentityGuard`): it validates the token against the
target-projected issuer and authorizes the caller unit against the `called_by`
set Sol derives from `calls`. Only an explicit public exception makes a route
external. Authentication failures are 401, an authenticated caller outside the
derived set is 403, and a missing audience or trust projection fails closed. The
trust root is never taken from the incoming token's `iss`.

## Start here

- **Runnable example:** [`examples/pluto/app/demo_ts`](../../examples/pluto/app/demo_ts/README.md),
  a TypeScript `-svc` and `-worker` pair deployed alongside pluto's OCaml units.
- **What every Sol app must do, in any language:** the
  [application contract](../../docs/reference/README.md).
- **What TypeScript can and can't do today:** the
  [compatibility matrix](../../docs/deployment/compatibility.md). TypeScript is
  staged behind the production profile until its parity triggers are met
  (DEC-026 §2).
