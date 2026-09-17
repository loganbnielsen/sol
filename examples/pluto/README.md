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

With `sol local infra up`, `checkout_svc` is exposed through the local north-south URL:

```bash
curl -H 'Host: checkout-svc.pluto-checkout.localhost' \
  -H 'x-api-key: dev-internal-key' \
  http://localhost:8088/quote
```

For customer-cloud, set `ingress_host` in `checkout_svc/sol.toml` to your DNS
name, run `sol deploy customer_cloud/aws/us-east-1`, then create an
`A`/`CNAME` record for that host pointing at the ingress load balancer.
Cert-manager uses the configured cluster issuer for TLS.

## Production profile

`sol/pilot/aws/us-east-1.yml` selects the `production-single-region` profile;
`sol/prod/aws/us-east-1.yml` deliberately does not, because an environment's name
never makes a production claim.

A production target deploys immutable artifacts, not mutable tags. Pin each
workload to the digest the build pushed:

```bash
REGISTRY=123456789012.dkr.ecr.us-east-1.amazonaws.com
sol deploy pilot/aws/us-east-1 \
  --image-ref charge_svc="$REGISTRY/pluto/charge-svc@sha256:$CHARGE_DIGEST"
```

A bare `--image-ref <ref>` is accepted when the scope selects exactly one
service; a whole-workspace deploy needs one `<service>=<ref>` per workload (the
`app/demo_ts` services deploy the same way). `sol deploy` verifies each
reference exists in its registry before it applies anything.

```bash
sol deploy pilot/aws/us-east-1 --scope payments/charge_svc --dry-run \
  --image-ref charge_svc="$REGISTRY/pluto/charge-svc@sha256:$CHARGE_DIGEST"
```

Either form runs the profile preflight before anything touches a cluster. It
refuses until the target establishes every guarantee the profile requires — a
tag reference is itself one unmet guarantee — and lists each unmet guarantee
with who must act.

Every workload declares its framework language in `sol.yml`. This workspace's
OCaml services declare `language: ocaml`; the `app/demo_ts` pair declares
`language: typescript`, so the preflight reports TypeScript as not yet
qualified for the first profile (DEC-026 §2) rather than silently admitting it.
The exact supported set — CLI, OCaml version, Kubernetes, provider module and
chart versions — is published in
`docs/deployment/compatibility.md` in the Sol repository.

The pilot target declares the alert-delivery contract
(`alert_receiver_type`/`alert_receiver_url`/`alert_owner`/`alert_runbook_url`).
Exercise that route without a real incident:

```bash
kubectl -n monitoring port-forward svc/prometheus-alertmanager 9093:9093 &
sol alert test --target pilot/aws/us-east-1
```

The command's exit status proves the route is configured and reachable; the
delivered-and-acknowledged result is HARDEN-002's live evidence. Runbooks for
each required alert are in `docs/deployment/alert-runbooks.md`.

Availability is declared, not inferred from replica count (AUDIT-080).
`notify_worker` declares `availability = "node-failure-tolerant"` (with two
replicas and a consumer readiness/liveness pair on `/readyz`//`livez`), so Sol
renders a topology spread, a PodDisruptionBudget and an explicit drain grace for
it; `charge_svc` stays `single` and is reported honestly as such. The pilot and
prod targets declare the fixed `node_failure_headroom_nodes` the claim needs.
See `docs/deployment/workload-availability.md`.

See the "Production Profile" section of
`docs/deployment/self-hosted-substrate-contract.md` in the Sol repository.

## CLI commands

```bash
sol local infra up        # provision local k3d cluster + infra
SOL_API_KEY=dev-internal-key sol up
sol local status  # show running pods and endpoints
sol local migrate # apply database migrations
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
