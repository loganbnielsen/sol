# Dogfood/showcase plan — full production lifecycle on Pluto

**Status: plan only, not executed.** This document exists to scope the next
dogfood pass; running any part of it against AWS is HARDEN-run-scale work and
needs the same explicit authorization as HARDEN run 3. The local-substrate
portions can run independently at any time (no AWS approval needed) but are
not run here either, per this pass's instruction to prepare, not execute.

## The question this exercise answers

> Does Sol make building and operating a sophisticated backend substantially
> easier without forcing the developer to understand all of Terraform,
> Kubernetes, Helm, EKS, IAM, cert-manager, Prometheus, Redpanda, etc.?

Not maximum feature coverage. Every prior dogfood run
(`internal/pipeline/dogfood/RUN_*.md`) has been **local-substrate only** —
scaffold → build → `sol local infra up` → deploy → migrate → one HTTP
request → one Kafka message. That has already surfaced and fixed real
friction (FRIC-019 and others). What it has never exercised: production AWS
deployment, release/change, rollback, or diagnosing a live operational
problem — the second half of the user journey this plan scopes.

## Why now, not before

The production half of this journey was not previously worth dogfooding: a
fresh AWS target had no way to actually reach `sol deploy` (the `sol cloud
init` gap — DEC-030/INFRA-025, fixed this session) and no real publisher
identity to push through (HARDEN-002 finding 6 — INFRA-026, fixed this
session). Dogfooding the production path before those existed would have
just re-discovered the same gaps HARDEN-002's own live runs already found
with more rigor. Both are closed now (offline evidence; HARDEN run 3 is
their live qualification, not this).

## Reference application: Pluto

`examples/pluto` is the canonical reference app (not Venus/local-demo — those
are fixtures now, not public examples). Current coverage, read from the tree
rather than assumed:

| Capability | Present in Pluto today |
|---|---|
| HTTP service | `checkout_svc`, `charge_svc` |
| Postgres + migrations | `db/migrations/0001_notifications.sql` |
| Kafka worker | `notify_worker` (`node-failure-tolerant`, 2 replicas) |
| Service-to-service call | `charge_svc` → `checkout_svc` (`sol.toml` `[service] calls`) |
| TypeScript services | `demo_ts/order_svc`, `demo_ts/fulfillment_worker` (DEC-022 parity) |
| Ingress | `checkout_svc` (`infra.deploy.ingress_host`) |
| `sol-jobs` (leased Postgres jobs) | **absent** |
| `-fn` (scheduled function) | **absent** |
| Explicit retry/DLQ demonstration | **absent** (the framework has the mechanism; Pluto doesn't exercise it observably) |

The three "absent" rows are candidate gaps, not decided additions — per this
pass's instruction, do not implement into Pluto speculatively. If the
showcase run below finds it cannot exercise "jobs where appropriate" or
"finite/scheduled work where appropriate" meaningfully without one, *that
discovery* is what justifies adding it, recorded as its own ticket at that
time — not before.

## Journey checklist

Each step is scoped to what a competent external team would actually run,
in order. `L` = local substrate (no AWS, no approval needed to execute
later). `P` = production AWS (needs the same explicit go-ahead as HARDEN
run 3 — this plan does not distinguish "safe to just run" from "needs
approval" any further than that split).

1. **[L] Fresh clone to first request.** `sol new workspace` → `sol local
   infra up` → `sol local run` → curl. Already dogfooded repeatedly
   (RUN_2026-09-13.md et al.) — re-run only to confirm no regression, not to
   re-discover known friction.
2. **[L] Local iteration loop.** Edit a handler, re-run, observe the
   edit-compile-run cycle time claim in `TUTORIAL.md` against reality.
3. **[L] Migrations locally.** Add a migration, `sol local migrate apply`,
   confirm the gate order (schema before workload mutation, AUDIT-069).
4. **[L] Logs/metrics/traces locally.** Open Grafana, find the request from
   step 1 in Loki, find its metric in Prometheus, and (if traces are wired)
   its trace. Record what a first-time user has to already know to find
   these versus what Sol's own output pointed them to.
5. **[P] Bootstrap a disposable production account.** Follow
   `docs/deployment/production-bootstrap.md` literally, as an external
   operator would, including the newly-added publisher/deploy identity
   sections (INFRA-025/026) — this is the first live exercise of that doc's
   *readability*, not just its mechanism.
6. **[P] `sol cloud apply` to Ready.** Time it; record every place the
   operator had to look something up outside Sol's own output.
7. **[P] Configure `kube_context` for `deploy_role_arn`** using the printed
   `deploy_kubeconfig_command` output (INFRA-025) — first real user of this
   exact instruction; confirms whether the printed guidance is actually
   sufficient without additional AWS/EKS knowledge.
8. **[P] Publish images as the publisher identity** (INFRA-026) — assume the
   publisher role in a session distinct from whatever ran `sol cloud apply`,
   push, then `sol deploy --image-ref ...`. This is the first real exercise
   of the four-identity separation as an actual workflow, not just a policy
   document.
9. **[P] A representative transaction.** One HTTP request through
   `checkout_svc`/`charge_svc`, one Kafka message through `notify_worker`,
   confirmed via the same Grafana/Loki path as step 4 — same observability
   surface, now against production.
10. **[P] Release/change.** Ship a small, real code change through the full
    path (publish → deploy) and confirm the release record advances.
11. **[P] Rollback.** Deliberately deploy a broken revision, then `sol
    rollback`. Confirm the pointer behavior matches B4/B5 in
    `internal/qualification/aws/production-single-region-v1-matrix.md` — this
    journey step and that qualification row are the same action seen from
    two purposes (product experience vs. conformance evidence); don't
    duplicate effort collecting the same evidence twice.
12. **[P] Diagnose an operational problem.** Deliberately break something a
    real user would hit (bad env var, unreachable DB, a failing readiness
    probe) and use only Sol's own commands/output (`sol status`, `sol logs`,
    `sol target show --check`) to diagnose it — no direct `kubectl`/AWS
    console unless Sol's own surface is proven insufficient, which is itself
    a friction-ledger entry if it happens.
13. **[P] Teardown.** `sol cloud destroy` through the INFRA-023 prepare →
    verify → destroy → verify-absence lifecycle — the same destructive path
    HARDEN run 3 exercises, from the product-experience side rather than the
    conformance side.

## Product-friction ledger (template — fill in during the actual run)

| Category | Entries |
|---|---|
| Made dramatically easier | |
| Made somewhat easier | |
| Made harder | |
| Infra concepts the user still had to understand | |
| Places we reached beneath Sol's public abstraction | |
| Blocked reasonable customization | |
| Confusing CLI/error/docs behavior | |
| Abstraction leaks | |
| Missing escape hatches | |

For every abstraction that produced a "made harder" or "leak" entry, answer
before filing a ticket: *if a sophisticated user outgrows this opinion, can
they drop down one level without throwing away the rest of Sol?* — a "no"
is a more serious finding than a "yes, but it's undocumented."

## What this plan deliberately does not do

- Does not implement `sol-jobs`, `-fn`, or retry/DLQ into Pluto speculatively
  (see "Reference application" above).
- Does not resurrect Venus/local-demo as a second public example.
- Does not run any AWS command. Steps 5–13 require the same explicit,
  present-operator authorization as HARDEN run 3 before execution.
- Does not duplicate HARDEN-002's qualification evidence — steps 9–11 and
  13 intentionally reuse the same live actions HARDEN run 3 would take,
  observed for a different purpose (product experience vs. conformance),
  so a combined session could reasonably run both passes back to back
  rather than provisioning two separate disposable targets.
