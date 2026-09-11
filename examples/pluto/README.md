# Pluto

A Sol workspace with OCaml service examples (`charge_svc`, `checkout_svc`,
`notify_worker`) and the existing TypeScript demo pair under `app/demo_ts`.

## Build

```bash
eval $(opam env)
dune build
```

## Run locally

```bash
# Start Kafka (Redpanda) and Postgres
bash <path-to-sol>/cli/platform/local/scripts/ensure-broker.sh
bash <path-to-sol>/cli/platform/local/scripts/ensure-postgres.sh

# Run the worker (POSTGRES_URL is required — both services depend on Postgres)
KAFKA_BROKERS=localhost:9092 POSTGRES_URL=postgresql://postgres:dev@localhost:5432/sol_dev \
  dune exec app/comms/notify_worker/bin/main.exe

# In another terminal, run checkout. SOL_API_KEY is the shared internal key.
PORT=8081 SOL_API_KEY=dev-internal-key dune exec app/checkout/checkout_svc/bin/main.exe

# In another terminal, run payments. It calls checkout through CHECKOUT_SVC_URL.
POSTGRES_URL=postgresql://postgres:dev@localhost:5432/sol_dev \
  CHECKOUT_SVC_URL=http://127.0.0.1:8081 SOL_API_KEY=dev-internal-key \
  dune exec app/payments/charge_svc/bin/main.exe
```

`charge_svc` declares `calls = ["checkout/checkout_svc"]`. In a Sol cluster
that injects `CHECKOUT_SVC_URL` as a cluster DNS URL for the checkout
ClusterIP, so the east-west request never leaves the cluster network. The
generated per-pair NetworkPolicy is what permits that caller/target path.

```bash
curl localhost:8080/checkout-quote
# {"shipping_cents":799,"currency":"USD","trace_id":"..."}
```

With `sol dev up`, `checkout_svc` is exposed through the local north-south URL:

```bash
curl -H 'Host: checkout-svc.pluto-checkout.localhost' \
  -H 'x-api-key: dev-internal-key' \
  http://localhost:8088/quote
```

For customer-cloud, set `ingress_host` in `checkout_svc/sol.toml` to your DNS
name, run `sol deploy customer_cloud/aws/us-east-1`, then create an
`A`/`CNAME` record for that host pointing at the ingress load balancer.
Cert-manager uses the configured cluster issuer for TLS.

## CLI commands

```bash
sol dev up        # provision local k3d cluster + infra
SOL_API_KEY=dev-internal-key sol up
sol status        # show running pods and endpoints
sol migrate       # apply database migrations
```

## Project layout

```
events/payments/            ← Charged event contract (payments team owns)
app/payments/charge_svc/         ← OCaml HTTP service (POST /charges, calls checkout)
app/checkout/checkout_svc/       ← OCaml HTTP service (GET /quote, ingress exposure)
app/comms/notify_worker/         ← OCaml Kafka consumer (subscribes to Charged)
app/demo_ts/order_svc/           ← TypeScript HTTP service demo
app/demo_ts/fulfillment_worker/  ← TypeScript worker demo
db/migrations/                   ← SQL migration files
```
