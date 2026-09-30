---
id: FND-0073
type: audit-finding
severity: high
source: AWS attempt 32 (discovery specimen) — the charge request never returns
---

**Depends on:** None.

**Related:** FND-0072 (the deploy substrate ordering this attempt fixed),
`examples/pluto/app/payments/charge_svc/lib/handler.ml`,
`internal/qualification/records/2026-09-30-aws-attempt32-cloud-boundary-passes-deploy-blocked-at-substrate.md`.

# On AWS, `POST /charges` is accepted and never answered, after topic and schema both succeed

## What happened

With FND-0072 fixed, the discovery specimen reached the application contract for the first time:
both images built and pushed, `sol migrate apply` succeeded, `sol deploy` succeeded
(*"Done. 2 service(s) deployed."*), `charge-svc` was `1/1 Running` and serving on `:80`, and the
deploy established the scoped `sol-deploy` RBAC in both namespaces it entered.

The transaction then failed at its first request. From a Job inside `pluto-payments`, on the
service's own address:

```
> POST /charges HTTP/1.1
> Host: charge-svc.pluto-payments.svc.cluster.local
> Content-Type: application/json
> Content-Length: 60
} [60 bytes data]
* upload completely sent off: 60 bytes
* Operation timed out after 15002 milliseconds with 0 bytes received
```

The server accepts the connection and the body, and never sends a byte. The service's own log
shows only `sol-svc listening on :8080` — no request log, no error. The same hang occurs with a
30-second timeout, so it is not a slow first query.

## What is *not* the cause — each checked live

- **PostgreSQL.** `sol migrate apply` ran a Job against the same `POSTGRES_URL` earlier in this
  attempt and completed, and a Job in the app namespace opens TCP to
  `<cluster>-postgres.….us-east-1.rds.amazonaws.com:5432`. The secret carries `POSTGRES_URL` and
  `SOL_API_KEY`, and the configmap carries the full environment.
- **Kafka reachability.** From inside `pluto-payments`: schema registry `/subjects` → HTTP 200,
  broker TCP 9093 → open, Redpanda admin API → HTTP 200.
- **Topic and schema.** The broker's own log shows the service's retry loop creating
  `pluto-payments-charges` (`topic_already_exists`), and the registry lists
  `pluto-payments-charges-value`. So the service reaches Kafka and completes schema registration.
- **Advertised listeners.** `advertised_kafka_api` for the internal listener is
  `redpanda-2.redpanda.redpanda.svc.cluster.local.:9093` — a DNS name, and the Redpanda pods are
  `2/2 Running`.
- **The platform.** All three Redpanda brokers are Ready and the monitoring stack is up.

So the request path reaches Kafka, registers its schema, creates its topic, and then does not
return. The remaining candidate is the produce/delivery-receipt path itself as exercised on EKS —
`handle_charge pool` is the route that hangs, while `/health` answers immediately, and the worker
(`notify_worker`) logs nothing at all.

## Why this is filed rather than patched

The mechanism is inside the Kafka client's produce path, and nothing in this evidence points at
the platform's configuration, the app's configuration, or the cluster's authority model. Guessing
at it (a timeout change, a broker setting, a retry) would be exactly the patching-through this
qualification forbids. It needs the produce path traced with the same discipline FND-0071 and
FND-0072 got: reproduce it minimally, read the client's own state, and fix the cause.

## A qualification-machinery change that came with this, and why

The row's transaction used `kubectl port-forward`, which **no Sol identity may perform**: the
deploy identity holds `jobs` but not `pods/portforward`, the operator identity is `get`/`list`
only, and the cluster-access identity holds no pod authority at all. That is the least-privilege
model working, so the row now drives the transaction the way the product itself reaches a service
— a Job in the application namespace, using the deploy identity's existing `jobs` authority, and
reading the result from that Job's log. No authority was widened for it.

## Acceptance criteria

- The produce path is traced on a live AWS platform and the blocking operation named.
- A fresh AWS specimen completes the transaction: `POST /charges` returns an id, the worker
  consumes it, PostgreSQL holds the row, and `GET /notifications` serves it back.
- The fix does not add authority, and does not lengthen a timeout to make a stalled operation
  look healthy.
