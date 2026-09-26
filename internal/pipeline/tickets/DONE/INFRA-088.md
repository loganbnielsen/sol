---
id: INFRA-088
type: bug
severity: high
title: Point cert-manager's leader election at its own namespace so GKE Autopilot lets it lead
source: GCP Attempt 10 (main @ bc9062b0) forensic re-analysis — the established root cause of the platform install's cert-manager failure, FND-0010
---

**Depends on:** None.

**Related:** FND-0010 (the defect, with Attempt 10's evidence and established cause), FND-0060
(falsified — the earlier "scheduling delay" reading of the same run), `INFRA-087` (withdrawn),
`platform/cloud/modules/platform/main.tf` (`helm_release.cert_manager`), the harness discriminator
(`internal/qualification/gcp/live-qual.sh`), record
`internal/qualification/records/2026-09-26-gcp-attempt10-fnd0010-live.md`.

## 1. Established root cause

Attempt 10's frozen bundle shows, as facts:

- the chart is installed with its default `global.leaderElection.namespace` = **`kube-system`**
  (verified against the chart itself: `values.yaml`, plus `templates/rbac.yaml` and
  `templates/{deployment,cainjector-deployment}.yaml`, which create the `Role`/`RoleBinding` in
  that namespace and pass `--leader-election-namespace={{ .namespace }}` to both components);
- on the GKE Autopilot cluster, both components were **denied creating leases in `kube-system` for
  the whole install window** — `GKE Warden authz [denied by managed-namespaces-limitation]: the
  namespace "kube-system" is managed and the request's verb "create" is denied` — 30 attempts each,
  controller 15:16:46 → 15:27:59, cainjector 15:16:38 → 15:27:43;
- neither component ever acquired leadership, so **cainjector never injected the CA bundle**: the
  `ValidatingWebhookConfiguration` (created 15:15:47Z) has **no `caBundle` field at all**;
- the webhook therefore rejected its clients' TLS (`http: TLS handshake error … remote error: tls:
  bad certificate`) and cert-manager's own `check api --wait=10m` polled every ~5s from **15:17:28
  to 15:27:29 (601s)** before printing `error: timed out waiting for the condition`;
- the Job (`backoffLimit: 1`, pod `restartPolicy: OnFailure`, `activeDeadlineSeconds` unset,
  startTime 15:16:59Z) recorded one failure, the kubelet restarted the container, the Job deleted
  the pod, and `BackoffLimitExceeded` became the condition at 15:27:29Z/15:27:31Z.

So the platform install fails because **the check cannot pass while the CA bundle is missing**, and
the CA bundle is missing because **cert-manager's leader election is aimed at a namespace Autopilot
forbids it to write**. FND-0010's own remedy (a release wait long enough for the check's designed
window) was necessary and is now live-validated — the check really did run its full 10 minutes —
but it cannot make this pass: no amount of waiting injects the CA.

## 2/3. Responsible ownership layer, and why the fix belongs there

`platform/cloud/modules/platform/main.tf`, in `helm_release.cert_manager`'s values — the same layer
that already carries this chart's `installCRDs` and the FND-0010 timeout values.

- It is Sol's decision how the platform's charts are installed, and the value is per-install
  configuration, not a chart default Sol can rely on: the chart's `kube-system` default is legal on
  clusters that permit writes there (plain EKS among them, which is why AWS qualification never met
  this), and illegal on Autopilot by design. The provider is deliberately restricting its own
  managed namespace, so the provider is not the thing to change.
- It cannot live in the harness: a qualification run must install the platform exactly as the
  product does, or it qualifies something else.
- No generic lifecycle code is involved: the fix is one declared value on one release, and the
  chart does the rest (Role/RoleBinding created in the target namespace, both components pointed
  there).

## 4. Proposed fix (smallest)

In `helm_release.cert_manager`, set the leader-election namespace to the release's own namespace:

```hcl
  # GKE Autopilot manages kube-system and denies workloads the create verb there, so the
  # chart default (global.leaderElection.namespace: kube-system) makes cert-manager's
  # controller and cainjector fail leader election for as long as the install runs -- and a
  # cainjector that never leads never injects the webhook's caBundle, so the chart's own
  # post-install check can never pass (FND-0010, Attempt 10: 30 denials each, no caBundle,
  # 601s of failing TLS polls). The chart creates its leaderelection Role/RoleBinding in
  # whatever namespace this names and passes it to both components as
  # --leader-election-namespace, so pointing it at the release namespace is the whole fix.
  set {
    name  = "global.leaderElection.namespace"
    value = kubernetes_namespace.cert_manager.metadata[0].name
  }
```

No other change: no timeout change (the current budget is correct and now proven), no RBAC authored
by Sol, no `kube-system` write, no node-pool or toleration change.

## 4b. Executable regression guard

Extend the existing readiness guard family (`internal/ci/check_cert_manager_readiness.sh` plus its
mutation self-test) with a rule that the cert-manager release declares a leader-election namespace
**and that it is the release's namespace**, not `kube-system` — with mutations that remove the
value, set it to a literal `kube-system`, and set it to a different namespace, each rejected. That
is the same guard shape FND-0010's fix already uses, over the same file, so a future edit cannot
quietly restore the chart default. The offline lifecycle suite's cert-manager assertion can carry
the same expectation for the rendered values.

## 5. What a subsequent live run would discriminate

A fresh GCP attempt (new target key, its own state) in which:

- the controller and cainjector acquire a Lease **in `cert-manager`** (leases present there, none
  attempted in `kube-system`, no Warden denials in their logs);
- the `ValidatingWebhookConfiguration` gains a populated `caBundle`;
- the `startupapicheck` Job **Succeeds** well inside its 10-minute window, and the platform apply
  continues past cert-manager toward `Ready` (whatever the *next* component's behaviour is, it is a
  different failure with different evidence).

**Falsification for the fix itself:** the same `denied by managed-namespaces-limitation` line for
`kube-system` after the change would mean the value did not reach the components (chart path or
value name wrong), which the run's captured manifests would then say directly.

## Status

Implemented 2026-09-26. The value below is in `helm_release.cert_manager`; the guard and its
mutation self-test cover it. **Offline acceptance met; live qualification is the next run** (the
discriminator in section 5), and FND-0060 stays `FIXED_UNQUALIFIED` until it happens.

Originally promoted from `BACKLOG` on 2026-09-26: the operator approved this fix on the FND-0060
analysis review ("Approved. The existing Attempt 10 evidence establishes FND-0060 strongly enough to
implement the proposed fix without another evidence-only live run"), with two conditions recorded
there: the value is platform configuration rather than provider-conditional lifecycle behaviour,
and FND-0060 must land fixed-but-unqualified until live evidence exists.

## Explicitly out of scope

No live mutation without separate authorization. No change to FND-0010's timeouts, to the authority
matcher, or to any destruction semantics. No GKE node-pool, firewall, or DNS changes. The stale
`kube-system` leases that may exist from other clusters are not this ticket's subject.

## Completion notes (2026-09-26)

**Problem.** The platform install could not pass cert-manager's own readiness contract on a fresh
GKE Autopilot cluster: the chart's default leader-election namespace is `kube-system`, Autopilot
denies workloads the create verb there (GKE Warden `managed-namespaces-limitation`), so the
controller and cainjector never acquired leadership, cainjector never injected the webhook's
`caBundle`, and the post-install check polled its full 601s and timed out (Attempt 10's frozen
bundle; FND-0060).

**Root cause.** Chart default, inherited by Sol because Sol declared nothing. The chart creates its
leader-election `Role`/`RoleBinding` in `global.leaderElection.namespace` and passes that namespace
to both components as `--leader-election-namespace`, so the namespace is an install decision.

**Change.** One declared value in `helm_release.cert_manager`:

```hcl
  set {
    name  = "global.leaderElection.namespace"
    value = kubernetes_namespace.cert_manager.metadata[0].name
  }
```

By reference to the namespace resource this module already creates, so the namespace has one source
of truth, and deliberately unconditional: no provider branch asks whether a cluster would have
permitted `kube-system`. Sol places cert-manager's leader-election resources in cert-manager's
namespace everywhere.

**Executable evidence.**

- `internal/ci/check_cert_manager_readiness.sh` now also requires the leader-election namespace to be
  declared, to be the namespace resource reference (so `kube-system`, any other namespace, and any
  literal — including the right name written as a string — are refused), and to resolve *in this
  file* to `kubernetes_namespace.cert_manager` named `cert-manager`. It prints the resolved
  namespace in its summary line.
- `internal/ci/test_cert_manager_readiness_check.sh` adds six mutations, each rejected by the
  intended rule: value omitted; `kube-system`; another namespace; the right name as a literal; a
  reference to the wrong namespace resource; and the namespace resource renamed while the reference
  stays (the resolution check, not the spelling, catches that one). All fourteen mutations are
  rejected and the unmutated tree is accepted.
- The offline lifecycle suite (`internal/ci/test_cloud_lifecycle_offline.sh`) is unchanged and
  green: this value is consumed by Terraform at apply time, and the suite's cert-manager gate
  assertion is about the install sequence, which this does not touch.
- `terraform fmt -check` clean; the module validates (`terraform init -backend=false && terraform
  validate`).

**Demo/example coverage:** not applicable — this is a platform-install value for a Helm release, with
no `sol.toml` field, CLI surface, framework primitive or generated manifest for an app author to
read or run. The observable behaviour is the platform install reaching `Ready`, which is what the
qualification run establishes.

**Language parity (DEC-022):** no application-facing impact. The change is provider-platform
configuration; it introduces no primitive, contract, metric or retry semantic, and neither
application language observes it.

**Canonical merge SHA:** `git log --oneline -1 -- internal/pipeline/tickets/DONE/INFRA-088.md`.

**Acceptance criteria:** offline — met (guard + mutations + suites above). Live — pending: a fresh
qualification run whose discriminator shows leases acquired in `cert-manager`, none attempted in
`kube-system`, a populated `caBundle`, and the check Job succeeding.
