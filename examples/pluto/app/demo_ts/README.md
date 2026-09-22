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

From this directory (`examples/pluto/app/demo_ts`):

```bash
npm install
npm run build -w order-svc -w fulfillment-worker

# bring up local infra (broker, schema registry, Postgres, Loki, Tempo, Prometheus)
bash cli/platform/local/scripts/ensure-broker.sh
bash cli/platform/local/scripts/ensure-postgres.sh
bash cli/platform/local/scripts/ensure-loki.sh
bash cli/platform/local/scripts/ensure-tempo.sh
bash cli/platform/local/scripts/ensure-prometheus.sh

KAFKA_BROKERS=localhost:9092 SCHEMA_REGISTRY_URL=http://localhost:8081 \
  LOKI_URL=http://localhost:3100 TEMPO_URL=http://localhost:4318 \
  node order_svc/dist/index.js &

KAFKA_BROKERS=localhost:9092 LOKI_URL=http://localhost:3100 \
  TEMPO_URL=http://localhost:4318 POSTGRES_URL=postgresql://postgres:dev@localhost:5432/sol_dev \
  node fulfillment_worker/dist/index.js &

curl -X POST localhost:8080/orders -H 'content-type: application/json' \
  -d '{"order_id":"demo-1","item":"widget","quantity":3}'
```

The `ensure-*.sh` scripts live in the Sol repository, so this walkthrough needs a
Sol checkout. What it does *not* need is a Sol **npm workspace** — the package
dependencies resolve purely from npm.

Then check Grafana (Loki logs + Prometheus metrics) and Tempo — the
`receive_order` span from `order_svc` and `fulfill_order` span from
`fulfillment_worker` link into a single trace across the Kafka boundary.

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

Running the images needs the same environment variables as the local walkthrough
above, pointed at reachable infrastructure.
