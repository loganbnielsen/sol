# GCP Attempt 11 — cert-manager qualified live, and the next blocker behind it

**Outcome: cert-manager's failure is fixed and live-qualified; the platform still does not reach
`Ready`, and the reason is a different, newly exposed defect.** Attempt 10's chain is now observed
end-to-end in the positive direction:

```
cert-manager Helm install
      ↓  leader-election Role/RoleBinding created in the cert-manager namespace
      ↓  controller and cainjector acquire their Leases (in cert-manager, none in kube-system)
      ↓  NO GKE Warden managed-namespaces-limitation denial anywhere
      ↓  cainjector injects the CA bundle ("Updated object", caBundle 896 bytes populated)
      ↓  startupapicheck succeeds (Job removed by hook-succeeded; release complete in 2m13s)
```

The install then continued into the rest of the platform (alloy, tempo complete; loki, grafana,
ingress-nginx, argocd creating) and failed at the **full platform apply** with
`rolebindings.rbac.authorization.k8s.io "sol-platform-provisioner" already exists` for five
namespaces — a **new first blocker** (FND-0061), not the previous one. Evidence was frozen before
teardown, the supported destruction path ran clean, and both Terraform roots are empty.

## Run identity

| | |
|---|---|
| Revision | `main @ 17afc4b2` (DEC-050, #555); `main` CI green at that SHA; `sol --version` asserted equal to the worktree HEAD |
| Ancestors asserted | FND-0010 `aac3f3ef`, INFRA-088 `ccde4112`, INFRA-080 `3f1049f9`, Attempt-10 instrumentation `55eabbf8` |
| Cluster / target | `sol-qual-gcp-11` / `qual11/gcp/us-central1` — its own state key, confirmed empty before the run |
| Harness / bundle | `internal/qualification/gcp/live-qual.sh`; `/tmp/sol-gcp-qual-11`; `PHASE_TIMEOUT=2700` |
| Operator values | `IMPERSONATOR=user:lbendtlynielsen@gmail.com`, `LE_EMAIL=qualification@sol-harden-qualification.dev` |
| Live window | 18:14:33Z → 18:40:01Z (~25m 28s), including teardown |

## Preflight (read-only)

Identity `lbendtlynielsen@gmail.com`; project `sol-qualification` ACTIVE, billing enabled; fresh
state prefix empty; no cluster with the new name; `live-qual.sh verify` **19 disposable classes
ABSENT, 2 durable PRESENT, quota 0, no UNKNOWN rows**; delegation resolving (`ns-cloud-c1..c4`);
offline suites green (harness 131/131, cert-manager guard + 14 mutations).

## Timeline (UTC)

| Time | Event |
|---|---|
| 18:14:33 | durable root reconciled — already matches declared state, nothing created |
| 18:14:33 | `CloudBootstrap` begins |
| 18:23:4x | `[terraform-apply] ok (549.6s)` — GKE `RUNNING`, Cloud SQL `RUNNABLE` |
| 18:24:13 | `PlatformInstalling`; platform init ok |
| 18:24:42 | leader-election Role/RoleBinding created **in `cert-manager`** (chart release) |
| 18:25:44 | controller: `attempting to acquire leader lease cert-manager/cert-manager-controller` → **`successfully acquired`** |
| 18:25:56 | cainjector: transient conflicts retried → **`"Updated object"`** (CA data written) |
| ~18:26:4x | cert-manager release **`Creation complete after 2m13s`**; `startupapicheck` Job absent (hook-succeeded removed it) |
| 18:27:0x | `[platform-prerequisites-apply] ok (143.7s)` — namespaces, provisioner RBAC, cert-manager |
| 18:30:2x | **`[platform-apply] FAILED (201.6s)`** — `rolebindings ... "sol-platform-provisioner" already exists` (redpanda, ingress-nginx, monitoring, cert-manager, argocd) |
| 18:30:4x | `[provisioner-bootstrap-access-remove] ok (10.2s)` — install window closed on the failure path |
| 18:30:05–18:30:50 | discriminator captured (FND-0010 lens: classification `UNKNOWN` — correctly, since this is not one of its signatures), pre-teardown inventory, **evidence frozen** |
| 18:30:50 | `sol cloud destroy qual11/gcp/us-central1` |
| 18:30:5x–18:31:0x | `PreparingDestroy`; deletion guards lowered; **authority acquired** (`destroy-reconciliation-apply` 9.4s/3.3s) |
| 18:33:0x | **`platform-destroy ok (129.1s)`**; **authority released** (`provisioner-bootstrap-access-remove` 9.6s/2.4s) |
| 18:33:0x–18:38:5x | `Destroying`: `terraform-destroy ok (345.2s)`; verification: state empty, residue check inconclusive (recorded reason: no `gcp.project_id`), retention none — **`Done.`** |
| 18:40:01 | post-teardown inventory: **`teardown verified: absent`** |

## The FND-0060 discriminator (frozen in the bundle)

| Transition | Evidence (all captured while the cluster existed, in `/tmp/sol-gcp-qual-11/`) |
|---|---|
| Role/RoleBinding placement | `role.rbac.authorization.k8s.io/cert-manager:leaderelection`, `cert-manager-cainjector:leaderelection`, `cert-manager-webhook:dynamic-serving` — all in namespace `cert-manager`, created 18:24:42Z |
| No `kube-system` objects | none matching `cert-manager` in `kube-system` roles/rolebindings/leases |
| Leadership | `leases`: `cert-manager-controller` (holder `cert-manager-…-external-cert-manager-controller`), `cert-manager-cainjector-leader-election`; log line `successfully acquired lease cert-manager/cert-manager-controller` |
| No denial | zero `managed-namespaces-limitation` lines in the controller or cainjector logs |
| CA bundle | `ValidatingWebhookConfiguration/cert-manager-webhook`: `clientConfig.caBundle` **896 bytes**, base64 of a PEM certificate |
| Injection | cainjector `reconciler.go:142 "Updated object"` after two optimistic-concurrency retries (`unable to update target object with new CA data` → retried → success; recorded as benign retry noise, not a defect) |
| Check | release **`Creation complete after 2m13s`**; `startupapicheck` Job absent (`hook-delete-policy: …hook-succeeded`) |

## The new first blocker (FND-0061) — facts

- The config declares **two** `kubernetes_role_binding` resources over the same namespace set, both
  named `sol-platform-provisioner` in Kubernetes:
  `platform_provisioner` (subject: Group `sol:platform-provisioners`) and
  `platform_provisioner_gcp` (subject: the GCP provisioner ServiceAccount), the latter gated on
  `local.gcp_provisioner != ""`.
- The **targeted prerequisites apply** names `-target=module.platform.kubernetes_role_binding.platform_provisioner`
  — so that resource creates the objects and records them (state holds
  `kubernetes_role_binding.platform_provisioner`, serial 8 at freeze).
- The **full apply** then tries the `platform_provisioner_gcp[...]` addresses, whose Kubernetes
  names already exist → `already exists`, five errors, `platform-apply` failed.
- **INFERENCE:** deterministic for any fresh GCP target (both resources are always declared), and
  previously unobservable because cert-manager failed inside the prerequisites step, before the
  full apply ever ran. **AWS was not exercised this run** and the `_gcp` resource is empty there.
- **HYPOTHESIS (unverified):** the intended subjects may both be wanted (the group for humans, the
  service account for the provisioner); the defect is the shared Kubernetes name, not either
  subject. Choosing the fix is a design decision, deliberately not taken during the run.

## Destruction and postconditions (provider API, not Sol's report)

| Required | Result |
|---|---|
| Authority bracket | observed: acquisition plan+apply → `platform-destroy ok (129.1s)` → removal plan+apply → substrate destroy; no degraded preparation |
| platform Terraform state | **empty** — 0 resources, serial 12 |
| cloud Terraform state | **empty** — 0 resources, serial 16 |
| Independent verification | `teardown verified: absent`; 19 disposable classes ABSENT (reasons preserved where a probe is unreadable), quota 0 |
| Durable prerequisites | state bucket PRESENT, DNS zone PRESENT, delegation still resolving |
| Unexpected billable residue | none (independently swept: clusters, SQL, instances, disks, addresses all 0) |
| Manual/emergency action | **none** — every step a supported Sol command |

## Claims this run supports

- **FND-0060: live-qualified.** Every transition of its chain was observed in the positive
  direction, on a fresh target, at the fixed revision.
- **FND-0010: live-qualified, on its own narrow claim.** Its remedy is the release budget, and the
  evidence shows cert-manager's trust/readiness process *completing* inside that budget: the
  lease was acquired, the CA injected, the check's Job succeeded (release complete in 2m13s of a
  600s-per-attempt, 1800s-release budget). Not qualified merely because the old signature is
  absent.
- Reproduced, not newly claimed: failed-`PlatformInstalling` destruction and the authority bracket.

## What this run does not claim

`PlatformInstalling → Ready` (not reached), Ready-state destruction (`INV-DESTROY-1`/`-4` Ready
cases), AWS or any other provider, interrupted destruction, stale-state recovery, other lifecycle
starting states, and any backlog item. The residue probe's `inconclusive` reading is preserved as
reported, never read as absence.
