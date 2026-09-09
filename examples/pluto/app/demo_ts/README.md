# Sol's TypeScript framework parity

`order_svc` and `fulfillment_worker` are a real TypeScript service and worker
running on Sol's deploy machinery (CLI, Docker builds, Kubernetes manifests
are all language-neutral) and consuming Sol's own conventions via two
in-tree npm packages:

- [`@sol/kafka`](../../../../packages/sol-kafka) — schema registry
  ordering/fatality, explicit topic provisioning, the Confluent wire format,
  and decode/retry/crash routing.
- [`@sol/obs`](../../../../packages/sol-obs) — metric naming/label
  vocabulary, Loki push shape, and W3C traceparent propagation.

Both packages exist so a TypeScript service and an OCaml `sol-svc`/
`sol-worker` land in the same Grafana panels and the same Tempo traces
without an author having to reconstruct Sol's policy by hand — see each
package's own tests for the specific bugs a hand-rolled first attempt hit
(FEAT-033's spike) before these existed.

## Run it locally

From the repo root:

```bash
npm install   # installs the whole workspace: packages/* + this demo's services
npm run build -w @sol/obs -w @sol/kafka -w order-svc -w fulfillment-worker

# bring up local infra (broker, schema registry, Postgres, Loki, Tempo, Prometheus)
bash cli/platform/local/scripts/ensure-broker.sh
bash cli/platform/local/scripts/ensure-postgres.sh
bash cli/platform/local/scripts/ensure-loki.sh
bash cli/platform/local/scripts/ensure-tempo.sh
bash cli/platform/local/scripts/ensure-prometheus.sh

KAFKA_BROKERS=localhost:9092 SCHEMA_REGISTRY_URL=http://localhost:8081 \
  LOKI_URL=http://localhost:3100 TEMPO_URL=http://localhost:4318 \
  node examples/pluto/app/demo_ts/order_svc/dist/index.js &

KAFKA_BROKERS=localhost:9092 LOKI_URL=http://localhost:3100 \
  TEMPO_URL=http://localhost:4318 POSTGRES_URL=postgresql://postgres:dev@localhost:5432/sol_dev \
  node examples/pluto/app/demo_ts/fulfillment_worker/dist/index.js &

curl -X POST localhost:8080/orders -H 'content-type: application/json' \
  -d '{"order_id":"demo-1","item":"widget","quantity":3}'
```

Then check Grafana (Loki logs + Prometheus metrics) and Tempo — the
`receive_order` span from `order_svc` and `fulfill_order` span from
`fulfillment_worker` link into a single trace across the Kafka boundary.

Each service also has its own `Dockerfile`, built from the **repo root** as
build context (matching this repo's OCaml example convention) since both
depend on the sibling workspace packages:

```bash
docker build -f examples/pluto/app/demo_ts/order_svc/Dockerfile -t order-svc .
docker build -f examples/pluto/app/demo_ts/fulfillment_worker/Dockerfile -t fulfillment-worker .
```
