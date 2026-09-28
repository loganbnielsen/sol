---
id: FND-0066
type: audit-finding
severity: high
source: GCP qualification Attempt 16 (2026-09-27), revision c6d8a460
---

# The platform's pod requests exceed a single node's allocatable capacity, on the substrate the profile declares

**Depends on:** None.

**State:** `OPEN` — no remediation, and none attempted. The remedy is a sizing or a request-profile
decision and belongs to the operator: `DEC-054`.

## Observed (GCP qualification Attempt 16, 2026-09-27)

Fresh target `qual16/gcp/us-central1`, cluster `sol-qual-gcp-16`, on the GCP driver's own defaults. The
cloud root completed (cluster `RUNNING`, Cloud SQL `RUNNABLE`), `platform-prerequisites-apply` was
`ok (52.4s)`, and the full `platform-apply` then failed after `695.0s` on exactly two resources:

```text
│ Error: context deadline exceeded
│   with module.platform.helm_release.redpanda,
│   on ../../modules/platform/main.tf line 214, in resource "helm_release" "redpanda"
│ Error: context deadline exceeded
│   with module.platform.helm_release.loki[0],
│   on ../../modules/platform/main.tf line 366, in resource "helm_release" "loki"
```

At the failure capture, 58 of the cluster's 62 pods were `Running` and exactly **four** were
`Pending` — the two releases' required pods:

```text
monitoring/loki-chunks-cache-0	Pending	requests={"cpu":"500m","memory":"9830Mi"}	limits={"memory":"9830Mi"}	PodScheduled=False(Unschedulable)
redpanda/redpanda-0	Pending	requests={"cpu":"2","memory":"4Gi"}	limits={"cpu":"2","memory":"4Gi"}	PodScheduled=False(Unschedulable)
redpanda/redpanda-1	Pending	requests={"cpu":"2","memory":"4Gi"}	limits={"cpu":"2","memory":"4Gi"}	PodScheduled=False(Unschedulable)
redpanda/redpanda-2	Pending	requests={"cpu":"2","memory":"4Gi"}	limits={"cpu":"2","memory":"4Gi"}	PodScheduled=False(Unschedulable)
```

The scheduler, verbatim, and these four messages are the only failures of this class in 1287 lines of
cluster events:

```text
FailedScheduling pod/redpanda-0         0/3 nodes are available: 3 Insufficient cpu.
FailedScheduling pod/redpanda-1         0/3 nodes are available: 3 Insufficient cpu.
FailedScheduling pod/redpanda-2         0/3 nodes are available: 3 Insufficient cpu.
FailedScheduling pod/loki-chunks-cache-0 0/3 nodes are available: 3 Insufficient memory.
```

The nodes are healthy and unconstrained — three `Ready` nodes, **no taints**, `MemoryPressure=False`,
`DiskPressure=False`, `PIDPressure=False`, `Ready=True(KubeletReady)` — with **allocatable `1930m`
CPU and `6170268Ki` (≈ 6026 Mi) memory each**.

## Problem

The failure is arithmetic, not pressure. Each request exceeds an *empty* node's entire allocatable
capacity:

| Pod | Request | Node allocatable | Ratio |
|---|---|---|---|
| each `redpanda-*` | `2000m` CPU | `1930m` CPU | 1.04 × a node |
| `loki-chunks-cache-0` | `9830Mi` memory | `6026Mi` memory | 1.63 × a node |

No node of this shape can ever satisfy either request, so **no node count and no autoscaler can
schedule them**: the queue is not "the nodes are full", it is "this pod cannot fit on this kind of
node". (Three redpanda brokers ask `6000m` together against a pool total of `5790m` allocatable —
the same statement from the pool's side.) The platform therefore cannot install on the substrate, and
two of its nine releases time out rather than the apply reporting a resource-fit refusal.

**And the pool is not full.** Summing the captured pods' requests by the node each is on: the 58
scheduled pods commit **2.23 CPU of the pool's 5.79** and 3.74 GiB of its 17.65. Placing all four
unschedulable pods would take the demand to **8.73 CPU / 25.34 GiB**, and the largest single pod needs
**2.00 CPU / 9.60 GiB on one node** — so the required node shape follows from the largest pod, and
`e2-standard-2` (1.93 CPU / 5.88 GiB allocatable) fails both requirements on its own. Per-node detail
and the candidate shapes are in the run record, § *The pool is not full — the fit is per node*.

## Root cause

Three declarations that were never reconciled:

1. **The substrate** — `platform/cloud/gcp/cluster/variables.tf`:
   `node_machine_type = "e2-standard-2"` (2 vCPU / 8 GiB; 1930m / ≈ 6026 Mi allocatable after
   reservations) and `node_count = 3`. The run set neither, so this is what the product declares for
   GCP Standard. `node_count`'s own description states the intent the observation contradicts:
   *"Three gives the platform's observability and Kafka components room."*
2. **Redpanda** — `platform/cloud/modules/platform/variables.tf`:
   `redpanda_replicas = 3`, `redpanda_cpu_cores = 2`, `redpanda_memory = "4Gi"`. The observed request
   matches those defaults exactly, so the platform's own default asks for more CPU than a node the
   same repository provisions.
3. **Loki's chunk cache** — the upstream `grafana/loki` chart's default. Sol's values
   (`platform/shared/components.json`) choose `deploymentMode: Monolithic` and never touch
   `chunksCache`, so the chart's separate memcached component and its `9830Mi` request are inherited
   unexamined. The substring `9830` appears nowhere under `platform/`.

`DEC-049` / `INFRA-093` chose Standard with "sizing from driver variable defaults" and qualified the
*substrate* change (no Autopilot admission refusal, no default node pool). This finding is the next
consequence of that choice, and it is not GCP-specific in shape: the AWS driver's default is
`node_instance_types = ["m6i.large"]` — the same 2 vCPU / 8 GiB class. **No AWS run in the ledger has
reached a platform install**, so the AWS consequence is inference from declarations, not observation;
it is recorded as such and should be confirmed by the first AWS run that gets that far.

## Not the cause (recorded so it is not re-tested)

- **Storage** — the monitoring PVCs are `Bound`; the redpanda `datadir-*` PVCs are `Pending` with
  `WaitForFirstConsumer`, their correct state until the pod schedules, and no provisioning failure is
  recorded for them. Storage is downstream of scheduling here.
- **Disk quota** — `SSD_TOTAL_GB limit=1000 usage=320 free=680`; `FND-0062`'s wall is not in play.
- **Taints / admission** — no taint on any node; the prerequisites apply succeeded.
- **The Helm timeout** — the releases never had a chance to become ready. Changing the timeout would
  change the failure's latency, not its cause, and nothing in this finding asks for that.

## Decision required (do not fix in this unit)

The remedy space, with its tradeoffs, for `DEC-054`:

1. **Size the substrate to the platform's declared requests.** A ≥ 4 vCPU node fits a redpanda
   broker; a ≥ 16 GiB node fits the loki cache's `9830Mi`. `e2-standard-4` (4 vCPU / 16 GiB) fits both
   with little headroom; `e2-standard-8` (8 / 32) fits the platform's stated intent. Cost scales with
   the machine type, and `SSD_TOTAL_GB` per node scales with `node_disk_gb`, not with the machine type.
2. **Bring the platform's requests down to the substrate.** `redpanda_cpu_cores` (2 → ≤ 1.5) and/or a
   `chunksCache` override. This changes what the platform asks a cluster for, so it changes the
   production contract, and it should be argued from the platform's own sizing intent rather than from
   what a cheap default happens to fit.
3. **Both, with the qualification substrate documented as a floor.** Decide the *product's* minimum
   node shape from the platform's requests, then let the qualification profile use it.
4. **Autoscaling.** Note that this does not help: the requests exceed one node, so horizontal scaling
   cannot schedule them. Rule it out explicitly rather than trying it.

**Explicit non-goals for whoever picks this up:** do not change the Helm timeout, do not add a
node-count or machine-type fallback to provisioning, do not weaken the resource requests silently to
make a run pass, and do not treat "more nodes" as a remedy for a per-node fit failure.

## Impact

Every GCP attempt on Standard stops at the platform apply — `Ready`, Ready-state destruction,
`INV-SUBSTRATE-*` and every application-level row stay `NOT REACHED` — and the failure presents as two
Helm timeouts, which invites the wrong remedy. It also means the platform's own resource profile has
never been exercised against a substrate that can hold it, so the requests themselves are
unqualified.

## Acceptance criteria

- The decision is recorded, with the arithmetic stated (request vs per-node allocatable), and the
  ruled-out options named.
- Whichever option is chosen, a fresh live GCP attempt reaches at least `Ready`, or fails on a
  boundary *past* resource fit, with the four pods scheduled.
- The chosen substrate's node shape is stated wherever the GCP profile's defaults live, so the next
  reader does not have to re-derive the fit.
- Whether AWS's `m6i.large` default has the same consequence is confirmed or refuted by the first AWS
  run that reaches a platform install, and recorded either way.
