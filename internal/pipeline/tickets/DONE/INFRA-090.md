---
id: INFRA-090
type: bug
severity: medium
title: The qualification preflight must check disk quota against the volumes the platform will need
source: GCP Attempt 12 (main @ cf43aaee) — FND-0062, the first run to reach the observability stack
---

**Depends on:** None.

**Related:** FND-0062 (the finding, with the provider readings), the Attempt 12 record
(`internal/qualification/records/2026-09-26-gcp-attempt12-fnd0061-qualified-ssd-quota-blocker.md`),
`internal/qualification/gcp/live-qual.sh` (`inventory`/`verify`, `quota_usage`).

## What was observed (FACT, live)

Attempt 12 reached the platform's observability stack for the first time and stopped there: three
PVCs (`storage-loki-0` 10Gi, `prometheus-server` 8Gi, `storage-prometheus-alertmanager-0` 2Gi) never
bound, with `CreateVolume failed: … (QUOTA_EXCEEDED): Quota 'SSD…'`, while the pods stayed Pending.
The region reports `SSD_TOTAL_GB limit=500.0 usage=500.0` with the cluster up — five Autopilot nodes
at 100 GiB `pd-balanced` boot disks each — and `usage=0.0` after supported teardown. The platform
asks for 20 GiB. The lifecycle behaved correctly; the environment had no room.

**The preflight said the quota was fine.** Its probe reports zero usage of the cluster's Autopilot
CPU/memory budget and never reads regional disk quota, so it cannot see the one quota that decides
whether the platform's volumes can exist. That is a false negative in the gate whose purpose is to
refuse a run that cannot succeed.

## Status

**Implemented 2026-09-26.** Offline acceptance met; live acceptance is the next qualification run.
The qualification project's `SSD_TOTAL_GB` was raised from 500 GiB to **1000 GiB** and confirmed
effective (see the completion notes), so the next run is not blocked on the precondition this
ticket's finding described.

Originally promoted

Promoted from `BACKLOG` on 2026-09-26, after the operator's refinement of the model:

> Before installing platform components requiring persistent disks, observed available provider
> disk quota must be sufficient for Sol's declared minimum persistent-disk requirement.

with the explicit instruction not to predict Autopilot's node count or boot-disk consumption. The
implementation is the next PR; this one only moves the ticket.

## Required change

Teach the preflight to answer "can the volumes the platform will need actually be created here?":

- read the region's `SSD_TOTAL_GB` (and `DISKS_TOTAL_GB`) **limit and usage**, not just the cluster's
  Autopilot consumption;
- compare the remaining headroom against the bytes the platform's PVCs declare (the observability
  stack's `prometheus_persistent_storage`, loki's single-binary persistence, alertmanager — read
  from the module rather than hard-coded, or state the sum with its source) **plus the boot disks the
  cluster itself will create** (node count × the Autopilot boot disk size, which is what consumed
  the quota here);
- fail the preflight, with the numbers, when it does not fit — turning a 43-minute failed run into a
  five-second refusal;
- preserve the tri-state discipline: a read that fails is `UNKNOWN`, never "fine".

## Acceptance criteria

- The preflight refuses when remaining disk headroom is less than the platform's declared volume
  requests (mutation-tested against a fixture with an exhausted quota: the values from Attempt 12,
  `limit=500 usage=500`, must be refused).
- The refusal names the numbers it compared and where each came from.
- A read that fails is reported as UNKNOWN and fails the preflight, not silently passed.
- The quota probe stays read-only and stays in the qualification harness — no product-runtime
  provider-inventory work.

## Out of scope

Raising the project's quota (an operator action, recorded in FND-0062 as the environment fix), the
platform's PV sizing defaults (a separate product question if the defaults are to change), and
anything about the lifecycle, which behaved correctly in this path.

## Completion notes (2026-09-26)

**The model, as implemented.** The operator's refinement is the shape of the code:

| Part | Where it lives | Who owns it |
|---|---|---|
| limit and usage (observation) | `Sol_cli_provider_capabilities.t.disk_quota`, implemented for GCP by `Sol_cli_gcp_cluster.disk_quota` as one read-only `gcloud compute regions describe <region> --format=json` | the provider |
| the requirement | `Sol_cli_platform_storage.parts` / `minimum_gb` (20 GiB: prometheus server 8, alertmanager 2, loki 10) | Sol |
| the comparison | `Sol_cli_disk_quota.sufficient`, called by the apply sequence | Sol's lifecycle policy |
| the provider's future node behaviour | nowhere | deliberately not modelled |

**Placement (Attempt 12 is why).** The check runs in `Sol_cli_cloud_apply.execute` immediately
after `cloud_ready` and before `with_cluster_access` — the earliest point where the provider's own
footprint is inside the observed usage and the latest at which refusing still costs nothing.
Attempt 12 showed both failures of the other placements: before the cluster, usage read 0/500; by
the platform's turn, the volumes were already asked for.

**Quota semantics (established, not assumed).** Sol's storage class is `standard-rwo`, which GKE
backs with `pd-balanced` disks, and Compute charges those against the region's **`SSD_TOTAL_GB`** —
the quota the provider named when it refused Attempt 12's volumes (`CreateVolume failed …
(QUOTA_EXCEEDED): Quota 'SSD…'`) while the region reported `limit=500.0 usage=500.0`.
`DISKS_TOTAL_GB` is the separate quota for standard disks, which Sol does not request. The quota is
**regional**, so the region is what is read; a zonal call would be the wrong number.

**Demand derivation.** `Sol_cli_platform_storage` declares the three parts with their provenance,
and the provenance is honest about ownership: every one of the three sizes is the *chart's* default
(Sol enables persistence and sets no size), verified while implementing — `prometheus_persistent_storage`
is a **bool**, not a size, which is exactly the mistake the guard now catches.

**Executable evidence.**

- `cli/test/test_disk_quota.ml`: the Attempt 12 payload parses to the observed numbers; a quota the
  payload does not carry is an **error, never zero**; sufficiency is measured against the declared
  minimum (exactly-enough passes, one GiB short refuses with all three numbers); the declaration is
  self-consistent.
- `cli/test/test_cloud_apply.ml`: four policy cases — insufficient refuses **before** the
  prerequisites and the platform (asserted by recorded event order), sufficient proceeds in order
  (`cloud_ready → observe_disk_quota → apply_prerequisites → apply_platform`), an unobserved quota
  is *reported* rather than passed off as room, and an unreadable one fails closed.
- `internal/ci/test_cloud_lifecycle_offline.sh`: a GCP scenario whose stub reports an exhausted
  quota — the apply refuses naming `SSD_TOTAL_GB 500/500` and Sol's declared 20 GiB, does **not**
  attempt cluster access, does not begin a platform apply, and closes the bootstrap window.
- `internal/ci/check_platform_storage_requirement.sh` + its four mutations: the declaration is
  checked against the module it describes (persistence still enabled; every part attributing its
  size to the chart; no part claiming a Sol-owned size). Its first real catch was this ticket's own
  author.
- `internal/qualification/gcp/live-qual.sh`: records the provider's own quota independently in the
  inventory (`SSD_TOTAL_GB limit/usage/free`), and its classifier now answers
  `PROVIDER_DISK_QUOTA_EXCEEDED` for a provider `CreateVolume … QUOTA_EXCEEDED` refusal — direct
  provider evidence ahead of ambient pod symptoms. Harness suite: 133 → **138 assertions**.
- Also closed here, cheaply: FND-0061's instrumentation gap. A successful install now captures the
  provisioner ClusterRoleBinding and RoleBindings, so the next run *observes* both subjects on one
  object instead of inferring the detail.

**Qualification project quota (confirmed effective).** `SSD-TOTAL-GB-per-project-region` was raised
from 500 to **1000 GiB** via the Cloud Quotas API (`isEligible: true`, preference
`ssd-total-gb-us-central1`, contact email the qualification operator), and the region now reports
`SSD_TOTAL_GB limit=1000.0` — verified within a minute of the request. 1000 GiB leaves Sol's 20 GiB
declared minimum plus ~480 GiB beyond the 500 GiB footprint Attempt 12 observed, without modelling
that footprint.

**Demo/example coverage:** not applicable — a lifecycle precondition check on a cloud install path,
with no `sol.toml` field, CLI surface, framework primitive or generated manifest for an app author
to read or run. What it changes for an operator is *when* a doomed run stops: seconds instead of
forty-three minutes.

**Language parity (DEC-022):** no application-facing impact; no primitive, contract, metric or
retry semantic is involved.

**Canonical merge SHA:** `git log --oneline -1 -- internal/pipeline/tickets/DONE/INFRA-090.md`.
