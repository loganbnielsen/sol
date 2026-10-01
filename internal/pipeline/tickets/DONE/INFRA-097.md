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

## Completion notes

**Premise verified before starting (2026-10-01).** `soldev pipeline check INFRA-097` ran
`rg -q 'rollout' cli/lib/cloud/sol_cli_workload_scope.ml` and reported `premise: holds`.
`Sol_cli_workload_scope.kind_of_name` mapped only `Deployment`/`CronJob`/`Job`, `resource_of_kind`
named only those three, and `Sol_cli_manifest_yaml.rollout_doc` renders a `Rollout` from the same
`pod_template` the release reads — so the kind was still unreachable by the release.

**What changed.** `Sol_cli_workload_scope` declares the kinds it covers in one list —
`Deployment`, `CronJob`, `Job`, `Rollout` — and each kind is read on its own:
`list_args ~namespace ~kind` asks for `get <resource> -n <namespace> --output json`. The release in
`Sol_cli_cloud_wiring.release_workloads_result` walks that list, parses each listing for
workspace-owned pod templates, and collects the objects to remove. `Rollout` is the one
`optional_kind` — the kind a controller installs rather than the platform — and only for it does
`Sol_cli_kubectl.classify e = No_resource_type` read as absence; a failed read of a built-in kind is
still a failed release. Selection (`spec.template.metadata.labels`, `workspace=<workspace>`),
removal by name, the bounded pod wait, the declared-namespace scope, the deploy identity, and
degrade-don't-block are unchanged, so FND-0077's invariants hold as they did.

**Why per kind.** `rollout` is an `argoproj.io` custom resource another controller installs:
`docs/deployment/escape-hatches.md` states the `[infra.rollout]` escape hatch requires Argo Rollouts
in the cluster, and Sol's own platform module installs Argo CD, not Argo Rollouts. Naming `rollout`
beside the built-in kinds in one `kubectl get` would fail the whole read wherever that CRD is not
served, regressing FND-0077 on every other cluster. No RBAC change was needed and none was made: the
deploy identity's `sol-deploy` ClusterRole already grants `get`/`list`/`watch`/`create`/`update`/
`patch`/`delete` on `argoproj.io/rollouts`
(`platform/cloud/modules/platform/platform_deploy_rbac.tf`), so the read and the removal stay inside
the authority the deploy path already uses; nothing reads the release store, and no cluster-wide read
was introduced.

**Coverage.**
- Unit (`cli/test/test_cloud_destroy.ml`, 67 cases green): the mixed listing now expects
  `rollout/progressive` alongside the Deployment/Job/CronJob cases; a `Rollout`-only listing pins the
  pod-template shape and that a Rollout labelled on its own metadata is not selected; the read case
  pins `get deployment|cronjob|job|rollout -n <namespace>` with no multi-kind listing; one case pins
  that `optional_kind` is true only for `rollout`.
- Guard (`internal/ci/check_workload_release_order.py`): the kinds list is parsed and all four kinds
  must be covered, `list_args` must build its read from `resource_of_kind kind` (so the release cannot
  go back to one comma-joined listing), and the wiring must walk `Sol_cli_workload_scope.kinds` and
  read an unserved kind as absence.
- Mutation suite (`internal/ci/test_workload_release_order_check.py`): three new mutations, each
  rejected for the reason under test — the `Rollout` kind dropped from the list, the kinds read in one
  listing again, and the optional-kind tolerance removed. All fifteen mutations are rejected and the
  unmutated tree is accepted.
- Offline lifecycle (`internal/ci/test_cloud_lifecycle_offline.sh` with
  `internal/ci/lifecycle_fakes/kubectl`): the unserved run asserts every kind is read per namespace,
  that the release still removes the `Deployment` while the CRD is absent, and that the release does
  not report itself failed; a second run with the CRD served asserts the `Rollout` is removed by name
  — in the same `kubectl delete` as the Deployment — before the pod wait.

**Acceptance criteria.** Offline — met (guard, mutations, unit and lifecycle above). Live — not
established here: the first criterion is provider/controller behaviour for a target whose service
enables `[infra.rollout]`, which needs a cluster with Argo Rollouts installed — a controller Sol does
not install — so it is an authorization-gated live run, and `internal/qualification/README.md` keeps
each live run in its own ticket rather than assuming one. What offline evidence does establish is
that the new kind is read, selected by the same ownership label, and removed by name before the wait,
that an unserved CRD leaves the other kinds released, and that the failure mode stays closed: an
unreadable kind degrades the release, says so, and never claims an absence it has not established.
FND-0077's live acceptance covers the identical mechanism and objects for the built-in kinds.

**Demo/example: not applicable** — no `sol.toml` field, CLI command, framework primitive, tutorial
step or generated manifest changed; the change is which existing Kubernetes objects one lifecycle
step reads and removes.

**Language parity (DEC-022):** no application-facing impact. No schema-registry convention, wire
format, trace propagation, retry/DLQ semantic, metric vocabulary, lifecycle/shutdown contract,
config/secrets contract or job semantic changes, and neither application language observes which
Kubernetes objects the destroy releases.
