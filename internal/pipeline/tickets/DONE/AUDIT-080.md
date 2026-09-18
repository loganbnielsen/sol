---
id: AUDIT-080
type: audit-finding
severity: high
title: Implement explicit workload availability semantics for production
source: production-readiness reviews 2026-09-16; consolidates the PDB, worker-health and drain findings
---

**Depends on:** DEC-026, FEAT-083.

## Production guarantee

A workload admitted to `production-single-region` declares the failure it must
tolerate using a Sol-owned semantic such as `single` or
`node-failure-tolerant`. Sol renders and validates the minimum native controls
needed to make that claim true. Replica count alone is not an availability
guarantee.

Engineering must resolve the final semantic names and the valid matrix for
services, workers, functions and persistent volumes after DEC-026 and FEAT-083.
Do not expose PDB, affinity/topology, probe timing or termination-grace fields as
the application contract.

## Existing evidence consolidated here

- No PodDisruptionBudget is rendered for multi-replica workloads.
- Workers have no liveness/readiness signal, so a hung consumer can remain
  apparently healthy.
- Kubernetes termination grace is implicit and can race the framework drain
  timeout.
- There is no placement/spread or startup-probe contract, and replicas sharing a
  volume have undefined portable behavior (FEAT-083).

## Input from FEAT-089: which workers consume Kafka

DEC-026 §3 defines worker readiness for a worker that consumes Kafka. Sol has
no declaration yet that says which workers do. The Kafka durability ticket owns
that declaration; this ticket should use it rather than treating every worker
as a Kafka consumer.

## Implementation scope

- Add the smallest plan-level availability semantic approved by DEC-026.
- Validate unsupported primitive/replica/storage combinations before render.
- Render the placement, voluntary-disruption, startup/readiness/liveness and
  shutdown behavior necessary for that semantic.
- Keep fixed capacity; autoscaling is not part of this guarantee.
- Apply the capability contract equally to OCaml and TypeScript workloads.

## Conformance and acceptance criteria

- A `single` workload is reported honestly as not node-failure tolerant.
- For a claimed node-failure-tolerant HTTP workload, a rollout and node drain do
  not remove all ready capacity.
- Node loss restores required capacity within the bound selected in DEC-026.
- Slow startup is not killed by liveness before it can become ready.
- A worker whose runtime becomes irrecoverably unhealthy is detected and
  replaced without requiring an operator to notice consumer lag first.
- SIGTERM permits the declared drain behavior before Kubernetes may force-kill
  the process.
- Unsupported replica/persistence combinations fail before rendering and name a
  supported alternative.
- HARDEN-002 exercises rollout, node drain/loss and slow-start/drain behavior;
  unit/render tests alone do not satisfy the guarantee.

## Non-goals

- Zone-failure tolerance unless DEC-026 explicitly selects it.
- HPA/KEDA, cluster autoscaling or generic scheduling configuration.
- A stateful-member workload kind unless FEAT-083 decides to introduce one.

**Demo/example coverage:** Update one runnable production-profile example to
declare each supported availability semantic and demonstrate the resulting
behavior.

## Outcome (2026-09-17)

Availability is now a declared semantic, not a replica count. Offline proof is
here; the live rollout/drain/node-loss evidence is HARDEN-002's.

- **The declaration.** `[infra.scale] availability = "single" (default) |
  "node-failure-tolerant"` (`Sol_cli_availability`). The plan carries it, and
  the contract deliberately exposes none of PDB/affinity/topology/probe/grace.
- **The matrix fails before render.** `validate_availability` refuses a
  node-failure-tolerant function (scheduled jobs), a volume-backed workload
  (FEAT-083 pins one writable attachment) and fewer than two replicas, each
  naming a supported alternative. Because availability changes rendered
  placement/disruption/probes, it is recorded on the release (identity encoding
  bumped to `sol-release-v3`) and rollback reconstructs and re-validates it.
- **Rendered controls.** `node-failure-tolerant` renders a hard
  `topologySpreadConstraints` across `kubernetes.io/hostname` and a
  `PodDisruptionBudget` (`minAvailable: replicas-1`, rendered on both the
  Deployment and Rollout paths); every workload gets a startup probe and an
  explicit `terminationGracePeriodSeconds: 45` (> the 30s framework drain bound,
  closing the 30s/30s race).
- **Worker health (`Worker_health`).** `/metrics`, `/readyz` and `/livez` on the
  one metrics port. Readiness is the consumer-join state and **transitions both
  ways** — a rebalance makes the worker not-ready and it becomes ready again when
  the assignment returns; liveness is the **poll cadence** (no successful poll in
  30s ⇒ replace it), so a hung consumer is detected without waiting for someone
  to notice lag. A worker with no consumer state renders no liveness claim at
  all. This required two narrowly-observational `kafka-eio` callbacks
  (`on_assigned`/`on_revoked`/`on_poll`); Sol owns the policy on top.
- **Headroom.** The preflight's `workload_availability` fails closed unless the
  target declares `node_failure_headroom_nodes` >= the number of
  node-failure-tolerant workloads (fixed capacity; autoscaling is out of scope).
- **Demo.** `examples/pluto` declares both semantics: `notify_worker` is
  node-failure-tolerant (replicas 2), `charge_svc` stays `single`; the pilot and
  prod targets declare headroom. Docs: `docs/deployment/workload-availability.md`.

**Implementation versus evidence:** offline proof is the render tests (explicit
grace, consumer probes, no liveness for a non-consumer, PDB + topology spread,
no PDB for `single`), the plan-rejection tests (one replica, function), and the
preflight tests (headroom missing vs declared). HARDEN-002 must exercise a
rollout, a node drain and node loss against a real cluster (no all-ready-capacity
loss; capacity restored inside the DEC-026 bound), a slow start, a hung consumer
being replaced, and SIGTERM permitting the declared drain.

**Demo/example coverage:** `examples/pluto` as above.

**TypeScript parity:** The declaration, plan, render and preflight are
language-neutral, so an OCaml and a TypeScript workload get identical controls.
The worker-health endpoints are served by `sol-worker`, shared by both languages'
workers.

**TypeScript parity:** Capability and lifecycle behavior must be equivalent. If
the worker health implementation differs by language, both implementations ship
under this ticket or the unsupported language is explicitly excluded by DEC-026.
