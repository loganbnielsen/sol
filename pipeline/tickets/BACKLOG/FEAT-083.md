---
id: FEAT-083
type: feature
severity: medium
title: Define and enforce the semantics of replicas > 1 with a declared volume
source: code inspection 2026-09-15 — the PVC-vs-StatefulSet question turned up
  an unstated combination in the workload/storage model
---

**Depends on:** None.

**Related:** CODE_LAYER-016 (per-workload volume rendering), DEC-022.

Sol renders `svc`/`worker` as Deployments and materialises a PersistentVolumeClaim
per declared volume, mounted by the Deployment's pods
(`cli/sol/lib/sol_cli_manifest_yaml.ml:284-343`). Local Redpanda is the
opposite — a StatefulSet with `volumeClaimTemplates`
(`cli/platform/local/k8s/redpanda.yaml:5,53`). That split is deliberate and
correct: a StatefulSet introduces pet-like per-replica identity, which the
broker needs (`redpanda-0` owns `pvc-0`) and most services/workers do not.

The sharp edge is the *combination*. `replicas` comes from `sol.toml`
(`[replicas]`, default 1) and can be overridden by `sol.yml` scale
(`sol_cli_deployment_plan.ml:645-652`); a volume can be declared at the same
time; and nothing couples the two. Access mode is user-declared and validated
only for spelling — `ReadWriteOnce | ReadOnlyMany | ReadWriteMany`
(`sol_cli_toml.ml:66,380`). No code path rejects or explains `replicas > 1` with
a single shared PVC, and no test covers the combination.

Three materially different developer intents are therefore collapsed into one
rendered shape:

- **A — one durable volume mounted by the workload.** Deployment + PVC.
  Legitimate and common: uploads, artifacts, caches that survive restarts. The
  workload is still cattle — `svc-0` need not remain `svc-0`.
- **B — one durable volume per replica.** Requires StatefulSet +
  `volumeClaimTemplates` (`worker-0 → pvc-0`, …). Stable per-replica identity;
  *not* something Sol's app workload abstraction currently offers.
- **C — one shared filesystem for arbitrary replicas.** Deployment + an
  RWX-capable backend, i.e. driver-dependent.

Today, `replicas = 3` + `[[volumes]]` renders approximately "three pods, one
PVC" and intentionally or not relies on whatever the storage driver permits.

## Remediation

Give the combination a defined meaning instead of leaving it to the cluster's
CSI driver:

1. Confirm the current rendered behaviour for `replicas > 1` + a declared
   volume, and pin it with a render test either way.
2. Choose the contract — reject the combination (fail closed, naming the
   alternatives), or accept it with documented semantics and an explicit
   warning for access modes that cannot satisfy it (`ReadWriteOnce` × replicas
   across nodes is the footgun).
3. Record that per-replica persistent identity is a *distinct* capability (B),
   not a change to `svc`/`worker` defaults.

## Non-goals

- Not converting `svc`/`worker` to StatefulSets — most workloads are cattle.
- Not adding a per-replica-identity workload kind here; that would be its own
  ticket if it is ever justified.
- Not StorageClass/snapshot management (out of scope per CODE_LAYER-016).

## Acceptance criteria

- `replicas > 1` with a declared volume has a defined, tested, documented
  meaning.
- An access mode that cannot satisfy that meaning either fails closed or warns
  explicitly.
- The Deployment-vs-StatefulSet boundary is documented where volumes are
  declared.
