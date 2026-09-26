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
