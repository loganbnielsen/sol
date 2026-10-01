---
id: FND-0079
type: audit-finding
severity: high
source: fixing FND-0077 — the destroy's release discovery names only some of the workload kinds Sol deploys
title: The destroy cannot release a progressive-delivery Rollout
---

**Depends on:** None.

**Related:** FND-0077 (`Sol_cli_workload_scope`, the release step),
`docs/deployment/escape-hatches.md` (`[infra.rollout]`), FEAT-011 (Argo Rollouts).

# The destroy cannot release a progressive-delivery Rollout

## What happened

FND-0077's correction made the destroy discover the workloads it must release by reading, in each
declared namespace,

```
kubectl get deployment,cronjob,job -n <namespace> --output json
```

and selecting the ones whose **pod template** carries the `workspace` ownership label. That is the
right selection, and it is the same shape `Sol_cli_rollback.live_workloads` already uses — except that
`live_workloads` covers a third live kind, `Live_rollout`
(`live_kind_path Live_rollout -> "rollout", [ "spec"; "template"; "metadata"; "labels" ]`), and the
destroy's listing does not name `rollout` at all.

So a service that opts into progressive delivery renders an Argo Rollouts `Rollout` rather than a
`Deployment`, its pods carry the ownership label on `spec.template.metadata.labels` exactly as a
Deployment's do, and the destroy neither sees the `Rollout` nor removes it. Its pool keeps its
sessions, and the managed database refuses to be dropped — the failure FND-0077 is about, for a
workload kind the fix does not reach.

This was found while fixing FND-0077 and is **not** fixed there: the listing's kind set was
pre-existing and is what that change left alone.

## Why

Progressive delivery is a complete, documented, application-author-facing capability, not a spike:
`docs/ROADMAP.md` records `Progressive delivery ([infra.rollout], Argo Rollouts)` as complete,
`docs/deployment/escape-hatches.md` documents the `[infra.rollout]` section, and
`docs/guides/TUTORIAL.md` states that a service enabling it gets a `Rollout` where it would otherwise
get a `Deployment`. An author who sets it therefore gets a workload the platform's supported teardown
cannot release.

The listing asks for the three kinds in one `kubectl get`, which is also why the gap is not a
one-word widening: `rollout` is a custom resource, and asking for a type the cluster does not serve
fails the whole read. Where Argo Rollouts is not installed the read must stay a read of the kinds that
are there, which is what `Sol_cli_rollback.live_workloads` handles per kind with
`Sol_cli_kubectl.classify e = No_resource_type`.

## Acceptance criteria

- A supported destroy of a target whose service enables `[infra.rollout]` removes the `Rollout` and
  waits for its pods, so the managed database's drop is not refused by sessions those pods hold.
- The read still degrades rather than blocking when a kind cannot be read, and still says nothing
  about absence it has not established.
- The scope stays the declared namespaces, as the deploy identity; no cluster-wide read, no widening
  of the provisioner identity, and no dependency on the release store (FND-0077's invariants hold
  unchanged).
- Coverage: a unit case pinning the `Rollout` template shape, and a guard or mutation that fails if
  the listing stops naming the kind again.
- State in one line in the completion notes whether a runnable example or demo applies; this changes
  no `sol.toml` field, no CLI command and no generated manifest, so it likely does not — but the
  verdict is recorded rather than assumed.
