# Sol's TypeScript framework parity

`order_svc` and `fulfillment_worker` are a real TypeScript service and worker
running on Sol's deploy machinery (CLI, Docker builds, Kubernetes manifests
are all language-neutral) and consuming Sol's own conventions via four published
npm packages:

- [`@sol-fab/kafka`](https://github.com/loganbnielsen/sol-kafka) — schema
  registry ordering/fatality, explicit topic provisioning, the Confluent wire
  format, and decode/retry/crash routing.
- [`@sol-fab/obs`](https://github.com/loganbnielsen/sol-obs) — metric naming/label
  vocabulary, Loki push shape, and W3C traceparent propagation.
- [`@sol-fab/svc`](https://github.com/loganbnielsen/sol-typescript) — the service
  lifecycle contract `order_svc` runs on: bounded drain and idempotent
  `SIGTERM`/`SIGINT`, matching the OCaml `sol-svc`.
- [`@sol-fab/worker`](https://github.com/loganbnielsen/sol-typescript) — the
  worker lifecycle contract `fulfillment_worker` runs on, matching the OCaml
  `sol-worker`.

The four exist so a TypeScript service and an OCaml `sol-svc`/
`sol-worker` land in the same Grafana panels and the same Tempo traces
without an author having to reconstruct Sol's policy by hand — see each
package's own tests for the specific bugs a hand-rolled first attempt hit
(FEAT-033's spike) before these existed. `kafka` and `obs` each live in their own
repository with their own CI, including the broker-backed retry/DLQ tests;
`svc` and `worker` share
[`loganbnielsen/sol-typescript`](https://github.com/loganbnielsen/sol-typescript).

This example is the *runnable* TypeScript path, not the scaffolded one: `sol new`
writes OCaml units only, so these two units were authored by hand (FEAT-084
tracks the scaffolding gap). It is also deployed for real in CI
(`golden-path-smoke-ts`).

This directory is deliberately its **own npm project root**: its own
`package.json` and `package-lock.json`, resolving `@sol-fab/*` from npm with no
dependence on an enclosing JavaScript workspace. It is the conformance fixture
for DEC-024 — the Sol workspace boundary is `sol.yml` (`examples/pluto`), and a
Sol workspace must not need an enclosing npm workspace to consume the packages.
Note this is a *property the example demonstrates*, not a rule Sol imposes: a
user is free to organise their workspace however they like, including a root
`package.json` shared by several services.

## Run it locally

Both units run through Sol, from the workspace root (`examples/pluto`), once
their npm dependencies are installed:

```bash
cd examples/pluto
(cd app/demo_ts && npm ci)      # the units' dependencies; the loop needs them
sol local infra up              # k3d cluster + broker, schema registry, Postgres, Loki, Tempo, Prometheus
sol local run --scope=demo_ts
```

`sol local run` builds each unit with `npm run build` in `app/demo_ts` — the npm
project that owns both packages — and runs the built entry with `node`, prefixed
`[demo_ts/<unit>]` so you can follow both in one terminal. Sol starts them
itself, so Ctrl-C stops both. It also injects the local substrate's addresses
(`KAFKA_BROKERS`, `SCHEMA_REGISTRY_URL`, `POSTGRES_URL`, `LOKI_URL`, `TEMPO_URL`,
`KAFKA_SECURITY_PROTOCOL=plaintext`), which is what the units read.

In another terminal, send one order through the whole path:

```bash
curl -X POST localhost:8080/orders -H 'content-type: application/json' \
  -d '{"order_id":"demo-1","item":"widget","quantity":3}'
```

Then check Grafana (Loki logs + Prometheus metrics) and Tempo — the
`receive_order` span from `order_svc` and `fulfill_order` span from
`fulfillment_worker` link into a single trace across the Kafka boundary.

A unit whose `sol.yml` entry declares no language is refused by the loop rather
than guessed at, and a unit with no installed dependencies is reported with the
`npm ci` to run — Sol never decides a workload's language from its files.

## Docker

Each service has its own `Dockerfile`, built with the **Sol workspace root**
(`examples/pluto`, the directory holding `sol.yml`) as build context — not the
Sol repository root, and not the service directory. Both images install
`@sol-fab/*` from npm:

```bash
cd examples/pluto
docker build -f app/demo_ts/order_svc/Dockerfile -t order-svc .
docker build -f app/demo_ts/fulfillment_worker/Dockerfile -t fulfillment-worker .
```

The build splits in two so the npm install stays cached against the manifests
rather than the source: both units' `package.json`/`package-lock.json` are copied
and `npm ci` runs before any source is copied.

The runtime stage ships the workspace's single shared install plus **only this
unit's** tree. The sibling's workspace symlink inside `node_modules` then points
at nothing, which is inert because nothing resolves it at runtime.

Running the images needs the same environment variables as the local walkthrough
above, pointed at reachable infrastructure.
