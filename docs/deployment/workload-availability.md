# Workload availability for `production-single-region` (AUDIT-080)

A workload admitted to the production profile declares the failure it must
tolerate. Sol renders and validates the minimum native controls that make the
claim true; the raw controls (PodDisruptionBudget, affinity/topology, probe
timings, termination grace) are never the application contract.

## The declaration

```toml
# app/comms/notify_worker/sol.toml
[infra.scale]
replicas = 2
availability = "node-failure-tolerant"   # or "single" (the default)
```

| Semantic | Meaning | Sol renders |
| --- | --- | --- |
| `single` (default) | No failure-tolerance claim. A replica count alone is not a guarantee. | Nothing extra; reported honestly as not node-failure-tolerant. |
| `node-failure-tolerant` | The workload survives losing one node. | `replicas >= 2` + a hard `topologySpreadConstraints` across `kubernetes.io/hostname`, a `PodDisruptionBudget` `minAvailable: replicas-1`, a startup probe, and the framework-appropriate readiness/liveness probes. |

## The valid matrix

Enforced by the plan *before render* (`validate_availability`), each rejection
naming a supported alternative:

- **Functions** are scheduled jobs — availability is not applicable;
- a **persistent volume** pins one writable attachment (FEAT-083), so a
  volume-backed workload can only be `single`;
- **fewer than two replicas** cannot survive a node loss — raise
  `replicas` or declare `single`.

## Headroom

Node-failure tolerance is only real if the node can be replaced. The target
declares the spare capacity it keeps:

```yaml
target:
  node_failure_headroom_nodes: 1   # one spare node's capacity per tolerant workload
```

The preflight's `workload_availability` guarantee fails closed when the
declaration is missing or smaller than the number of node-failure-tolerant
workloads. Autoscaling is not part of this guarantee: the capacity is fixed and
declared.

## Probes: what "healthy" means per workload

- **HTTP service** — `startupProbe` and readiness/liveness on `/healthz:8080`.
  The startup probe means a slow start is not killed by liveness before it can
  become ready.
- **Kafka consumer worker** — readiness on `/readyz` and liveness on `/livez`,
  both on the metrics port (`9090`), plus a startup probe.
  - *Readiness* is the consumer-join state: the broker has assigned partitions.
    A rebalance that takes them away makes the worker not-ready, and it becomes
    ready again when the assignment returns — readiness transitions both ways,
    it does not latch true.
  - *Liveness* is the **poll cadence**: a consumer that stops polling is stuck
    even though its process is up, so it is replaced instead of left looking
    healthy. A worker whose runtime becomes irrecoverably unhealthy is detected
    without waiting for someone to notice consumer lag.
- **Worker with no consumer state** (e.g. a `sol-jobs`-only worker) — no
  liveness claim, because there is nothing meaningful to observe. Sol renders no
  probe rather than a default that asserts nothing.

`/metrics`, `/readyz` and `/livez` are served on the one metrics port (see
`Worker_health`), so the probes need no second listener.

## Drain

Every rendered pod sets `terminationGracePeriodSeconds: 45`, strictly larger
than the framework's 30s drain bound, so SIGTERM always has room to finish the
declared drain before Kubernetes may force-kill the process. The two 30s
defaults otherwise race.

## What the offline tests do and do not prove

Unit/render tests prove the controls are rendered and that unsupported
combinations are refused before render. They do **not** prove the claim: HARDEN-002
must exercise, against a real cluster, that a rollout and a node drain do not
remove all ready capacity, that node loss restores required capacity inside the
DEC-026 bound, that slow start is not killed, that a hung consumer is replaced,
and that SIGTERM permits the drain.

## Scope

- Availability is per workload; a `single` workload is reported honestly rather
  than silently upgraded.
- Zone-failure tolerance is **not** claimed (DEC-026 does not select it),
  autoscaling (HPA/KEDA) and generic scheduling configuration are out of scope,
  and no stateful-member workload kind is introduced.
- The contract applies equally to OCaml and TypeScript workloads; it is
  language-neutral.
