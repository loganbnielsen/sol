# FND-0062 — The platform install cannot provision its volumes when the project's SSD quota is consumed by the cluster's own node boot disks

- **Classification:** `ENVIRONMENT_PRECONDITION` (live: GCP Attempt 12's frozen bundle and the
  provider's own quota reading; the lifecycle behaved correctly throughout)
- **State:** `FIXED_UNQUALIFIED` — fixed 2026-09-26 in `INFRA-090`: the lifecycle now observes the
  provider's regional disk quota after the substrate exists and before the platform asks for a
  volume, compares it against Sol's declared minimum, and refuses with the numbers (or fails closed
  if the quota cannot be read). The harness records the same quota independently and classifies a
  provider `QUOTA_EXCEEDED` refusal directly. The qualification project's `SSD_TOTAL_GB` was also
  raised 500 → 1000 GiB and confirmed effective. **Not qualified:** no live run has yet installed
  the platform with the volumes binding; the next one is the discriminator.
- **First identified:** 2026-09-26, GCP Attempt 12 (`main @ cf43aaee`) — the first run to reach the
  platform's observability stack, because every earlier attempt failed before it
- **Provider:** GCP / GKE Autopilot
- **Derived ticket:** `INFRA-090`
- **Evidence class:** `LIVE` (bundle `/tmp/sol-gcp-qual-12`)

## What happens (FACT)

The platform apply installs its releases and then waits, correctly, for the observability stack.
Three PVCs never bind — `storage-loki-0` (10Gi), `prometheus-server` (8Gi),
`storage-prometheus-alertmanager-0` (2Gi), all `standard-rwo` — and the pods stay `Pending`:

```
error generating accessibility requirements: no topology key found for node gk3-sol-qual-gcp-12-pool-1-…
rpc error: code = Unavailable desc = CreateVolume failed: … failed to insert zonal disk:
  unknown error when polling the operation: rpc error: code = ResourceExhausted
  desc = operation … failed (QUOTA_EXCEEDED): Quota 'SSD…'
```

and the quota the provider reports for the region:

```
SSD_TOTAL_GB  limit=500.0  usage=500.0      ← at the limit, cluster up
SSD_TOTAL_GB  limit=500.0  usage=0.0        ← after supported teardown
```

Five Autopilot nodes, each with a 100 GiB `pd-balanced` boot disk, account for exactly the 500 GiB.
The platform asks for 20 GiB in total, and there is none left. After teardown the usage returns to
zero — the same quota, with the cluster gone — which is what makes the attribution certain rather
than inferred.

**Consequence:** the Helm releases for loki and the prometheus stack time out
(`context deadline exceeded`, 1342 s for the platform apply), so the platform does not reach
`Ready` on a project whose SSD quota has no headroom above its node boot disks.

## What this is, and what it is not

It is **not** a lifecycle defect: prerequisites applied, cert-manager installed, the RBAC objects
were created without conflict, releases installed until they reached a volume that the provider
refused to create, the failure was reported, the install window closed, and destruction returned
both roots to empty. Every Sol-owned behaviour in that path was correct.

It is a **precondition of the environment**, with two consequences worth acting on:

1. **The qualification project needs disk headroom.** Either raise `SSD_TOTAL_GB` on the project or
   accept that the platform's 20 GiB of PVCs cannot coexist with a cluster of this size at the
   default 500 GiB. This is an operator action, not a code change.
2. **The harness preflight did not see it.** Its quota probe reported `quota absent` (zero *usage* of
   the Autopilot CPU/memory budget) while `SSD_TOTAL_GB` was exhausted, because it does not read
   regional disk quota at all. A preflight that says "quota fine" while the volumes the platform
   needs cannot be created is a false negative of exactly the kind the qualification discipline
   exists to prevent.

## What would settle it

- A preflight probe that reads the region's `SSD_TOTAL_GB` (and `DISKS_TOTAL_GB`) **limit versus
  usage**, compares the remaining headroom against the platform's declared PVC requests plus the
  node boot disks the cluster will create, and refuses to launch when it does not fit. Read-only,
  cheap, and it turns a 43-minute failed run into a five-second refusal.
- Then the ordinary next run: with headroom, the PVCs bind, loki and the monitoring stack become
  ready, and the install continues toward `Ready` and Ready-state destruction.

## Not claimed, not fixed

No product change; no workaround applied in-run (no quota check bypassed, no PVC size edited, no
storage class changed, no manual disk creation). The run observed, classified, froze evidence, and
tore down through the supported path.
