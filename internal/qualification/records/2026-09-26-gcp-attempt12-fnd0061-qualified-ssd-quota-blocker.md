# GCP Attempt 12 — FND-0061 fixed and qualified live; the next blocker is the project's SSD quota

**Outcome: the RBAC collision is gone and the platform install got past it for the first time. The
run then stopped at a different, newly reachable boundary: the observability stack's PersistentVolumeClaims
cannot be provisioned, because the project's `SSD_TOTAL_GB` quota is fully consumed by the GKE
Autopilot nodes' own boot disks.** Supported teardown ran clean, both roots are empty, and the
quota returned to zero as soon as the cluster was gone — which is what makes the diagnosis certain.

## Run identity

| | |
|---|---|
| Revision | `main @ cf43aaee` (INFRA-089, #558); main CI **green** at that SHA before launch; `sol --version` asserted equal |
| Ancestors asserted | FND-0010 `aac3f3ef`, INFRA-088 `ccde4112`, INFRA-080 `3f1049f9`, Attempt-10 instrumentation `55eabbf8`, FND-0061 `cf43aaee` |
| Cluster / target | `sol-qual-gcp-12` / `qual12/gcp/us-central1` — its own state key, confirmed empty before the run |
| Harness / bundle | `internal/qualification/gcp/live-qual.sh`; `/tmp/sol-gcp-qual-12`; `PHASE_TIMEOUT=2700` |
| Live window | 20:25Z → 21:08Z (~43 min), including teardown |

### Preflight (read-only)

Identity/project/billing OK; fresh prefix empty; no cluster named `sol-qual-gcp-12`; delegation
resolving (4 NS); inventory **19 disposable classes ABSENT, 2 durable PRESENT, quota 0, no UNKNOWN
rows**; offline suites green (harness 133, ownership guard). **The preflight has no disk-quota
probe — see FND-0062.**

## Timeline (UTC, FACT)

| Time | Event |
|---|---|
| 20:25:06 | durable root reconciled (nothing created); `CloudBootstrap` |
| 20:33:4x | `[terraform-apply] ok (510.9s)` — GKE `RUNNING`, Cloud SQL `RUNNABLE` |
| 20:34:1x | `PlatformInstalling`; platform init ok |
| 20:36:2x | `[platform-prerequisites-apply] ok (124.2s)` — **cert-manager and the provisioner RBAC applied cleanly** |
| 20:36 | leader election in `cert-manager`, leases acquired, `caBundle` populated, release `Creation complete after ~2m` (as in Attempt 11) |
| 20:36:3x | `[platform-apply]` begins — **the boundary Attempt 11 failed at** — and passes it: **no `already exists` error anywhere** |
| 20:37–20:58 | releases install: alloy, tempo, grafana, ingress-nginx, argocd complete; loki and the prometheus stack wait |
| ~20:41 | three PVCs Pending (`storage-loki-0` 10Gi, `prometheus-server` 8Gi, `storage-prometheus-alertmanager-0` 2Gi, all `standard-rwo`) and four pods Pending |
| 20:58:5x | **`[platform-apply] FAILED (1342.1s)`** — Terraform `context deadline exceeded` (Helm release waits) |
| 20:59:0x | `[provisioner-bootstrap-access-remove] ok (8.7s)` — install window closed on the failure path |
| 20:59–21:04 | discriminator captured (classification `SCHEDULING_AMBIENT`), pre-teardown inventory, **evidence frozen** |
| 21:04:5x | `sol cloud destroy qual12/gcp/us-central1` |
| 21:05–21:07 | `PreparingDestroy` → guards lowered → authority acquired → **`platform-destroy ok (135.4s)`** → authority released |
| 21:07–21:13 | `Destroying` → **`terraform-destroy ok (346.6s)`** → verification → **`Done.`** |
| 21:08:41 | post-teardown inventory: **`teardown verified: absent`** |

## What the run proved (FACT)

**FND-0061 is fixed and qualified live.** The install passed the exact boundary that failed in
Attempt 11 — the full `platform-apply` created the platform's Kubernetes objects, including both
provisioner bindings, with **no `already exists` error**, and went on to install helm releases for
22 minutes. The collision no longer exists. *(Inference, labelled: because the applied configuration
declares both subjects on one object and the object was created without conflict, the created
RoleBinding/ClusterRoleBinding carry both subjects; the run did not capture those objects directly —
see the instrument note below.)*

**The next blocker is a provider quota, not Sol behaviour.** The three PVCs never bound:

- PVC events, verbatim: `error generating accessibility requirements: no topology key found for node
  gk3-sol-qual-gcp-12-pool-1-…`, then repeatedly
  `rpc error: code = Unavailable desc = CreateVolume failed: … failed to insert zonal disk: …
  (QUOTA_EXCEEDED): Quota 'SSD…'`;
- pods: `0/3 nodes are available: 1 Too many pods, 3 Insufficient cpu, 3 Insufficient memory`
  and, once a node existed, `running PreBind plugin "VolumeBinding": binding volumes: context
  deadline exceeded`;
- the quota itself: **`SSD_TOTAL_GB limit=500.0 usage=500.0`** with 5 Autopilot nodes, whose
  **100 GiB boot disks are `pd-balanced` and count against that same quota** — 5 × 100 = 500;
- the platform asks for **20 GiB** in total (10 + 8 + 2).

After teardown the same quota reads **usage=0.0**, which closes the inference: the 500 GiB was the
cluster's own nodes, and a project at this default quota has nothing left for the platform's
volumes. This is a **precondition of the environment**, not a defect in the lifecycle — and the
first run ever to reach it, because every earlier attempt failed before the observability stack.

## Destruction and postconditions (provider API)

| Required | Result |
|---|---|
| Authority bracket | observed; no degraded preparation |
| platform Terraform state | **empty** — 0 resources, serial 12 |
| cloud Terraform state | **empty** — 0 resources, serial 16 |
| Independent verification | `teardown verified: absent`; durable bucket and zone PRESENT; delegation resolving |
| Unexpected residue | none (independent sweep: clusters, SQL, instances, disks, addresses all 0; `SSD_TOTAL_GB` usage 0) |
| Manual/emergency action | **none** |

## Claims this run supports

- **FND-0061: live-qualified** — the platform apply passes the former collision boundary.
- Reproduced, not new: failed-`PlatformInstalling` destruction and the authority bracket;
  cert-manager's success (Attempt 11's qualified chain).

**Not claimed:** `Ready` (not reached), Ready-state destruction, AWS or any other provider,
interrupted destruction, stale-state recovery, other starting states, and any statement about the
observability stack beyond this quota-blocked environment.

## Instrument notes (recorded, not fixed during the run)

1. **The preflight's quota probe does not look at disk quotas.** It reported `quota absent` while
   `SSD_TOTAL_GB` was exhausted — it measures the cluster's Autopilot CPU/memory consumption, not
   regional disk quota. Filed as FND-0062 / INFRA-090.
2. The classifier answered `SCHEDULING_AMBIENT`, which is the honest fallback here (the pods are
   genuinely pending) but is not the cause: the direct signature was the Helm release
   `context deadline exceeded`, and the cause was the volume-binding quota failure captured in the
   PVC events. The corrected ordering (direct failed-operation first) did its job — there was no
   `already exists` this time — and the cause came from the provider events, not from the label.
3. The success-path discriminator captures no RBAC objects, so the "both subjects on one object"
   claim rests on the configuration plus the absence of conflict. A capture of the two bindings
   after a successful platform apply would close that gap in the next run.
