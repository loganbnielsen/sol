---
id: FEAT-083
type: feature
severity: medium
title: Define Sol's workload-identity and persistence semantics (replicas x volumes)
source: code inspection 2026-09-15 — an unstated replicas/volume combination was
  the evidence, not the whole problem
---

**Depends on:** None.

**Related:** CODE_LAYER-016 (per-workload volume rendering), DEC-022.

## Why this ticket is broader than its trigger

The trigger was narrow: `replicas > 1` plus a declared volume has no Sol-defined
meaning. The right fix is broader — **Sol has never explicitly defined what
persistent storage means in its workload model**, and that absence surfaced as
an undefined *combination* rather than as a wrong render. Patch the edge case
alone and the next undefined combination will just be discovered the same way.

## What exists today (the evidence)

- `svc`/`worker` render as **Deployments**, with a **PVC per declared volume**
  mounted by the Deployment's pods
  (`cli/sol/lib/sol_cli_manifest_yaml.ml:284-343`).
- `access_mode` is validated **only for spelling** —
  `ReadWriteOnce | ReadOnlyMany | ReadWriteMany` (`sol_cli_toml.ml:66,380`).
- `replicas` comes from `sol.toml` (`[replicas]`, default 1), overridable by
  `sol.yml` scale (`sol_cli_deployment_plan.ml:645-652`).
- **Nothing couples `replicas` with volumes**, and no test covers the
  combination. So `replicas = 3` + a volume renders "three pods, one PVC" and
  defers the meaning to whatever the CSI driver happens to permit.
- Local Redpanda is the opposite shape — a StatefulSet with
  `volumeClaimTemplates` (`cli/platform/local/k8s/redpanda.yaml:5,53`), which is
  right for a broker.

## The framing decision: identity, not capability

Deployment vs StatefulSet is a **semantic** choice, not a capability tier.
Deployment says *N interchangeable instances*; StatefulSet says *N individually
identified members*. StatefulSet is not "Deployment+".

The asymmetry that matters for a two-way door: starting with Deployment and
later adding a distinct stateful/member workload kind is **additive** — nothing
existing changes. Starting with StatefulSet makes ordinal identity *observable*
(`HOSTNAME == "payments-0"`, `payments-0.payments`, storage bound to an ordinal);
applications will depend on it, and removing it later is a compatibility break.

So the choice is not "Deployment because StatefulSet is more work". It is:
**interchangeability is the stronger, cleaner default for `svc`/`worker`, and
identity should be introduced only where Sol intends to promise it.**

## Prior to decide, not assume

Workload model:

```text
svc / worker   replicas are interchangeable        -> Deployment
fn             executions are independent          -> Job/CronJob
stateful kind  replicas have durable identity      -> StatefulSet  (now or explicitly deferred)
```

Storage is **orthogonal** to that, and is three distinct capabilities, not one:

```text
workload volume   one durable filesystem belonging to the workload
shared volume     several interchangeable instances share one filesystem (RWX backend)
replica volume    storage belongs to stable members (replica-0 -> data-0)
```

Kubernetes implements these with combinations of Deployments, StatefulSets,
PVCs, access modes and storage classes; Sol should name the *semantic* and pick
the primitive that faithfully implements it, not expose the primitive directly.

On `ReadWriteOnce`: do **not** build a portable platform contract out of RWO's
incidental ability to be mounted by more than one pod under some placements. If
Sol promises a multi-replica workload, its correctness must not depend on the
scheduler co-locating replicas or on CSI-specific behaviour.

## Deliverable

A written decision (this may warrant its own `DEC` if the owner prefers — the
ticket is the right container either way) that states:

1. the workload-identity semantics of `svc`/`worker`/`fn`, and whether a
   stateful/member kind is introduced now or explicitly deferred with a trigger;
2. the persistence capabilities above and how they are expressed (`sol.toml`);
3. the valid/invalid combination matrix, enforced fail-closed with messages that
   name the valid alternative.

## Acceptance criteria

- A render test **first** pins today's behaviour for `replicas > 1` + a declared
  volume, so the change is made against a known baseline rather than a
  misremembered one.
- Workload-identity and persistence semantics are written down, not implied by
  rendering.
- Invalid combinations fail closed — or warn explicitly where the contract is
  genuinely driver-dependent — instead of silently deferring to the CSI.
- The Deployment-vs-StatefulSet boundary is documented where volumes are
  declared.

## Non-goals

- Not switching `svc`/`worker` to StatefulSets as a default.
- Not implementing a stateful/member workload kind here unless the decision says
  so.
- Not StorageClass/snapshot management (out of scope per CODE_LAYER-016).
