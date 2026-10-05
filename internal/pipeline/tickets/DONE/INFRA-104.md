---
id: INFRA-104
type: infra
severity: medium
source: alpha.7 GCP attempts 1 and 5, 2026-10-04
title: Drive the alpha orders scenario in both language namespaces from the GCP app phase
---

**Depends on:** None.

## Premise verified

Re-verified 2026-10-04 on the INFRA-107 head. `write_target()` in
`internal/qualification/gcp/live-qual.sh` wrote `app_db: {omit: true}` and
`events: {omit: true}` while the enabled alpha `orders_svc` declares `uses: [app_db, events]`,
so the generated target did not declare the resources its workload uses. The separate app
target enabled `charge_svc`/`notify_worker` and the app phase drove `/charges` +
`/notifications`; the alpha orders scenario (`orders_svc`/`fulfilment_worker` OCaml,
`order_svc`/`fulfillment_worker` TypeScript) was never run, so a successful app phase could
not establish alpha B1/B4 for either namespace, and the B3 relay row was never observed.

## Remediation

The cloud target now declares `app_db` and `events` and enables the alpha units in both
language namespaces, omitting the legacy `charge_svc`/`notify_worker` pair and
`checkout_svc`. The cloud phase runs `sol check` after writing the target and before it
reconciles the durable root or applies anything, so declarations are validated before
provider mutation. The app phase builds and pushes `orders_svc`, `fulfilment_worker`,
`order_svc` and `fulfillment_worker`, deploys them, then drives the alpha orders scenario
once per namespace: `POST /orders` (B1, checked to carry the submitted id) and a read-back
of `GET /orders/<id>` until the order reaches `fulfilled` or `confirmed` (B4). Each
namespace's transaction is a separate port-forward and transcript; `alpha-rows.txt` records
which rows each namespace ran, and marks B3 `not-run` because its outbox relay ordering and
broker ack need Kafka-topic inspection this HTTP phase does not perform. The legacy
`/charges` path is no longer exercised or produced.

## Acceptance criteria

- The generated target declares the service's resources and passes `sol check` before
  provider mutation.
- The app phase drives the orders scenario for both the OCaml and TypeScript namespaces
  with independent effect assertions, and records which alpha rows it actually ran.
- Legacy charges evidence cannot be presented as the new orders/outbox/jobs contract
  passing.
- The runnable GCP procedure states the alpha-row to provider-row/evidence mapping.
- Language-parity: neither namespace may be silently omitted.
- Example impact: none; qualification machinery and its procedure only.

## Checks

- `internal/qualification/gcp/test-live-qual.sh` — 314 passed. New/updated assertions: the
  cloud target declares `app_db`/`events` and both language unit pairs, and `sol check`
  appears before `sol cloud apply` in the invocation order; the app phase builds and pushes
  each unit from its own Dockerfile; `app-transaction-ocaml.txt` and `app-transaction-ts.txt`
  each record a read-back that reached fulfilled or confirmed; `alpha-rows.txt` records B1
  as `run` for both namespaces; the curl transcript contains `/orders` and never `/charges`
  or `/notifications`; and a stalled read-back (status never `fulfilled`) fails the phase
  with no row recorded as `run`.
- `internal/qualification/gcp/gcp-production-single-region-v1-matrix.md` documents the
  B1/B3/B4 → INV-IDENT-1 / INV-SUBSTRATE-1 evidence mapping once.
- `python3 internal/qualification/gcp/test_observer.py` — 38 passed;
  `internal/ci/check_no_comments.sh` and `check_durable_dns_zone.py` pass.

## Completion notes

The GCP app phase now exercises the real supported product surface (the alpha orders
scenario) in both language namespaces rather than a legacy charges fixture, and states
exactly which rows its success establishes. **Live validation of the app phase is blocked on
INFRA-108/BUG-206**: the platform's documented `redpanda-users` pre-platform prerequisite is
established under BUG-206, and until then the app phase cannot be run live. That is not a
failure of this ticket; the harness, target and offline checks are complete and the live app
run is tracked by INFRA-108. B3 (outbox relay ordering and broker ack) remains unasserted by
the HTTP app phase and is recorded as `not-run`, not as passing.
