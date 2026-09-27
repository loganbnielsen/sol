# GCP qualification Attempt 14 (2026-09-26) — past the storage boundary, stopped by GKE Autopilot admission

## Summary

| | |
|---|---|
| revision | `ae47d777` (current `main`; `d301426f` and all five required ancestors are ancestors of it, main CI green) |
| target | `qual14/gcp/us-central1`, cluster `sol-qual-gcp-14`, project `sol-qualification`, fresh state prefix |
| result | **install stopped at the platform's Helm releases**; evidence frozen before teardown; supported destruction completed and independently verified |
| first blocker | **GKE Autopilot Warden admission** refusing `helm_release.prometheus` and `helm_release.redpanda` |
| FND-0063 | **crossed live** — the real `terraform output` payload parsed, the project established, the quota observation performed |
| FND-0062 | **the check is live-qualified** — observation, requirement, policy result and continuation, all printed; the *volume-binding* claim was not reached, because the blocker is upstream of it |
| billable residue | none: no clusters, SQL, disks, registries, addresses or `sol-qual-gcp-14` service accounts; `SSD_TOTAL_GB 0/1000` |

## The ordered chain, as it actually happened

| time (UTC) | step | evidence |
|---|---|---|
| 02:56 | preflight | `disk-quota: PRESENT (SSD_TOTAL_GB limit=1000 usage=0 free=1000)`, all disposable classes ABSENT, `state-bucket`/`dns-zone` PRESENT, prefix `sol/qual14/` matched no objects |
| 02:57 | launch | fresh target, fresh state key |
| 03:04 | cloud root applied | cluster `sol-qual-gcp-14` provisioning; one 100 GiB boot disk |
| ~03:10 | **parser boundary crossed** | the run continued past `Sol_cli_cluster.outputs_reader` — the FND-0063 defect's error never appeared |
| ~03:10 | **disk-quota policy** | verbatim: `platform volumes: SSD_TOTAL_GB 100/1000 GiB used (900 GiB free), and the platform's declared minimum is 20 GiB (prometheus server 8 GiB; prometheus alertmanager 2 GiB; loki (single binary) 10 GiB)` |
| ~03:12 | platform prerequisites | `[platform-prerequisites-apply] ok (145.7s)` — **past Attempt 12's stopping point** |
| ~03:12–03:17 | full platform apply | three GKE Warden admission rejections (below); apply failed |
| 03:17 | evidence frozen | pre-teardown inventory, Sol run record, **both roots' state captured** (platform state existed and was read), discriminator capture |
| 03:17–03:26 | supported destruction | `PreparingDestroy` → deletion protection disabled → platform teardown `ok (136.7s)` → `Destroying` → substrate destroy → verification by evidence |
| 03:26 | verified absent | `teardown verified: absent`; durable prerequisites present |

The authority bracket was exercised exactly once in each direction: `provisioner_bootstrap_admin=true`
(acquire) and `=false` (release), one occurrence each in the destroy log.

## The first blocker, verbatim (provider admission, not ambient symptoms)

Three Terraform errors during the platform apply, all from GKE's own admission webhook:

```
admission webhook "warden-validating.common-webhooks.networking.gke.io" denied the request:
GKE Warden rejected the request because it violates ...
  Violations details: {"[denied by autogke-disallow-hostnamespaces]":
    ["enabling hostNetwork is not allowed in Autopilot.","enabling hostPID is ...]}
  with module.platform.helm_release.prometheus, on ../../modules/platform/main.tf line 1456

admission webhook "warden-validating.common-webhooks.networking.gke.io" denied the request:
  Violations details: {"[denied by autogke-default-linux-capabilities]":
    ["linux capability 'SYS_RESOURCE' on container 'tuning' not allowed; ...]}
  with module.platform.helm_release.redpanda, on ../../modules/platform/main.tf line 314
```

Two distinct platform components, two distinct Autopilot policies: prometheus's manifests ask for
`hostNetwork`/`hostPID` (the node-exporter pattern), and Redpanda's `tuning` container asks for
`SYS_RESOURCE`. Autopilot refuses both by policy; Sol's platform defaults do not accommodate that.
Nothing was patched, restarted, resized or retried during the run.

## What this specimen advances, and what it does not

**Advances:**

- **FND-0063 → qualified.** The real Terraform output boundary was crossed and the quota observation
  performed, with the lifecycle continuing — not merely the absence of the old error.
- **FND-0062's check → live-qualified.** The provider's own limit, usage and free capacity, Sol's
  declared 20 GiB requirement, and the policy's pass were all observed live, and the lifecycle
  continued past the check into the prerequisites. The quota also shows why the raise mattered:
  usage reached 500 GiB with the cluster's own nodes, exactly the wall Attempt 12 hit, with 500 GiB
  of headroom left.
- **The prerequisite phase completes on this revision**, and the destroy path works from a
  *partially installed* platform: the platform root held 262 KiB of real state and Terraform
  destroyed all of it (`platform-destroy ok`, disposable root empty).

**Does not advance:**

- **`Ready`** — not reached; the blocker is upstream of the readiness contract.
- **PVC binding (10 + 8 + 2 GiB)** — the volumes belong to loki/prometheus, whose Helm releases
  never applied, so this run says nothing new about the storage boundary Attempt 12 could not cross.
- **Supported Ready-state destruction** — this is destruction from a *failed* install, which is a
  different starting state; it qualifies that path only.
- **FND-0061's binding capture** — the capture is attached to the success path, and the install did
  not succeed. The inference therefore stands, and the harness should capture the bindings after the
  *prerequisites* phase, which did succeed here.
- **Anything about AWS, other providers, interrupted destruction, or stale-state recovery.**

## Instrument observations

- The discriminator classifier answered `SCHEDULING_AMBIENT` for a failure whose direct signature is
  an admission denial: the harness has no rule for `warden-validating` / `GKE Warden rejected`, so a
  provider refusal was classified by ambient Kubernetes symptoms. This is the pattern the operator
  has flagged twice; the signature is narrow and authoritative and belongs ahead of the symptoms.
- The bundle for this run was complete, and legitimately so: both roots were reached, both states
  exist, and the phase-aware rule required both.
