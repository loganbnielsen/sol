---
id: INFRA-097
type: bug
severity: high
title: Release a progressive-delivery Rollout before the destroy drops the database
source: audit finding FND-0079 — the destroy's release discovery names only some of the workload kinds Sol deploys
premise: 'rg -q ''rollout'' cli/lib/cloud/sol_cli_workload_scope.ml'
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0079-the-destroy-cannot-release-a-progressive-delivery-rollout.md`

## Problem

`Sol_cli_workload_scope.list_workloads_args` asks for `deployment,cronjob,job`, so the destroy's
workload release cannot see an Argo Rollouts `Rollout` — which is what the `-svc` primitive renders
when a service sets `[infra.rollout]` (FEAT-011; `docs/deployment/escape-hatches.md`). A `Rollout`
carries the `workspace` ownership label on `spec.template.metadata.labels`, exactly where the release
already looks, so the only gap is that the listing does not name the kind. The consequence is
FND-0077's failure for that shape of service: the pool's sessions stay open, and the managed
database refuses the drop, so a single supported destroy does not converge.

This is not a one-word widening. `rollout` is a custom resource: naming it in the same `kubectl get`
fails the whole read where Argo Rollouts is not served, so the read must tolerate a kind that is not
there — the way `Sol_cli_rollback.live_workloads` does, per kind, treating
`Sol_cli_kubectl.classify e = No_resource_type` as absence rather than failure.

## Remediation

Teach the release to cover the `Rollout` kind without weakening FND-0077's invariants: the read stays
namespaced, runs as the deploy identity, and degrades rather than blocking; the scope still comes from
the target's declared namespaces and ownership still comes from the observed pod template; nothing
reads the release store. An unserved kind must read as absence, not as a failed read that would skip
the wait.

## Acceptance criteria

- A destroy of a target whose service enables `[infra.rollout]` removes the `Rollout`, waits for its
  pods, and the managed database's drop is not refused in that same invocation.
- A cluster that does not serve `rollout` still releases `Deployment`/`Job`/`CronJob` workloads: an
  unserved kind is absence, not a degraded release.
- The guard `internal/ci/check_workload_release_order.py` and its mutation suite hold the new kind,
  and a mutation that drops it is rejected for the reason under test.
- A unit case pins the `Rollout` pod-template shape alongside the existing `Deployment`, `Job` and
  `CronJob` cases.
- Completion notes state the demo/example verdict in one line and the DEC-022 language-parity
  verdict in one line (no application-facing convention changes here, so the latter is expected to be
  "no language-parity impact").
