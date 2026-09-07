# Pluto

A Sol workspace with two services: `charge_svc` (HTTP) and `notify_worker` (Kafka consumer).

## Build

```bash
eval $(opam env)
dune build
```

## Run locally

```bash
# Start Kafka (Redpanda) and Postgres
bash <path-to-sol>/platform/local/scripts/ensure-broker.sh
bash <path-to-sol>/platform/local/scripts/ensure-postgres.sh

# Run the worker (POSTGRES_URL is required — both services depend on Postgres)
KAFKA_BROKERS=localhost:9092 POSTGRES_URL=postgresql://postgres:dev@localhost:5432/sol_dev \
  dune exec app/comms/notify_worker/bin/main.exe

# In another terminal, run the service
POSTGRES_URL=postgresql://postgres:dev@localhost:5432/sol_dev \
  dune exec app/payments/charge_svc/bin/main.exe
```

## CLI commands

```bash
sol dev up        # provision local k3d cluster + infra
sol up            # build images and deploy to cluster
sol status        # show running pods and endpoints
sol migrate       # apply database migrations
```

## Project layout

```
events/payments/          ← Charged event contract (payments team owns)
app/payments/charge_svc/  ← HTTP service (publishes Charged on POST /charges)
app/comms/notify_worker/  ← Kafka consumer (subscribes to Charged)
db/migrations/            ← SQL migration files
```
