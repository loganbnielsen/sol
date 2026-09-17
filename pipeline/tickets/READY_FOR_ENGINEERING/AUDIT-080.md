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

**TypeScript parity:** Capability and lifecycle behavior must be equivalent. If
the worker health implementation differs by language, both implementations ship
under this ticket or the unsupported language is explicitly excluded by DEC-026.
