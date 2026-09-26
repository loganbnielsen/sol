# FND-0060 — cert-manager's leader election targets `kube-system`, which GKE Autopilot denies, so the platform install cannot pass its own webhook check

- **Classification:** `VERIFIED_DEFECT` (live: GCP Attempt 10's frozen bundle, cross-checked against
  the chart's own values and templates)
- **State:** `QUALIFIED` (live, 2026-09-26, GCP Attempt 11 at `main @ 17afc4b2`) — every step of
  the chain was observed in the positive direction on a fresh target: leader-election
  Role/RoleBinding created in the `cert-manager` namespace, `successfully acquired lease
  cert-manager/cert-manager-controller`, cainjector's lease held, **no** `managed-namespaces-limitation`
  denial anywhere, cainjector `"Updated object"` with the webhook `caBundle` populated (896 bytes),
  and cert-manager's release `Creation complete after 2m13s` with its `startupapicheck` Job removed
  by `hook-succeeded`. Evidence frozen in `/tmp/sol-gcp-qual-11`; record
  `internal/qualification/records/2026-09-26-gcp-attempt11-cert-manager-qualified-new-blocker.md`
- **First identified:** 2026-09-26, GCP Attempt 10 (`main @ bc9062b0`)
- **Provider:** GCP / GKE Autopilot. The defect is *not* provider-conditional in its fix: Sol should
  place cert-manager's leader-election resources in cert-manager's namespace everywhere, because
  that is the namespace the release is installed into, not because a given cluster forbids anything
- **Derived ticket:** `INFRA-088` (`INFRA-087` withdrawn — see below)
- **Evidence class:** `LIVE` (bundle `/tmp/sol-gcp-qual-10`, 286 files)

## The defect

`cert-manager` v1.14.4's chart defaults `global.leaderElection.namespace` to **`kube-system`**; it
creates its leader-election `Role`/`RoleBinding` in that namespace and passes
`--leader-election-namespace={{ .namespace }}` to both the controller and the cainjector. On GKE
Autopilot that namespace is managed, and the write is denied — for the *entire* install window:

```
User "system:serviceaccount:cert-manager:cert-manager" cannot create resource "leases"
in API group "coordination.k8s.io" in the namespace "kube-system":
GKE Warden authz [denied by managed-namespaces-limitation]: the namespace "kube-system" is
managed and the request's verb "create" is denied
```

30 denials each (controller 15:16:46 → 15:27:59, cainjector 15:16:38 → 15:27:43). Neither ever
acquired leadership, so **cainjector never injected the CA bundle** — the
`ValidatingWebhookConfiguration` (created 15:15:47Z) has **no `caBundle` field at all** — so every
client's TLS handshake to the webhook failed and cert-manager's own post-install
`check api --wait=10m` polled for its full 601s (122 handshake failures, every ~5s, 15:17:28 →
15:27:29) before timing out. The Job recorded one failure and moved to `BackoffLimitExceeded`.

**Consequence:** the platform install cannot pass its own readiness contract on a fresh GKE
Autopilot cluster, so `PlatformInstalling → Ready` — and therefore `Ready`-state destruction — is
unreachable.

## Falsified in the same bundle: the scheduling-delay hypothesis

The first reading of this run (filed as FND-0060, ticketed as INFRA-087) concluded a ~9½-minute
scheduling/container-start delay from Kubernetes **event ages**. The authoritative fields refute it:
Job `startTime` 15:16:59Z, container args `check api --wait=10m -v`, `backoffLimit: 1`,
`activeDeadlineSeconds` unset, pod `restartPolicy: OnFailure`, `failed: 1`, describe
`0 Active / 0 Succeeded / 1 Failed` with exactly **one** pod created. The `Created`/`Started` events
38s before capture are the post-failure **container restart** `OnFailure` performs. The check ran
its whole window; it was never waiting to be scheduled. `INFRA-087` is withdrawn as originally
framed — this finding's subject is the defect above.

## Fix (landed, INFRA-088)

`global.leaderElection.namespace = kubernetes_namespace.cert_manager.metadata[0].name` in
`helm_release.cert_manager` — one declared value, unconditional, guarded by
`check_cert_manager_readiness.sh` (declared, by reference, resolving to cert-manager's namespace;
`kube-system`, other namespaces and literals all refused) plus six mutations, including a renamed
namespace resource so the guard follows the reference rather than its spelling.

## What would qualify it (not merely fix it)

A live GCP run in which the controller and cainjector acquire their Lease in `cert-manager`, the
webhook configuration carries an injected `caBundle`, the `startupapicheck` Job **Succeeds**, and
the platform install continues past cert-manager — ideally on to `Ready`. Until that happens this
finding stays fixed-but-unqualified, and no state above `FIXED_UNQUALIFIED` is claimed.

## Live qualification — GCP Attempt 11 (2026-09-26)

Fresh target `qual11/gcp/us-central1`, cluster `sol-qual-gcp-11`, at `main @ 17afc4b2`. The fix was
in place (the `global.leaderElection.namespace` reference to the cert-manager namespace resource,
with its guard and mutations) and the chain ran to completion:

| Transition | Evidence |
|---|---|
| placement | `role.rbac.authorization.k8s.io/cert-manager:leaderelection`, `cert-manager-cainjector:leaderelection`, `cert-manager-webhook:dynamic-serving` — all in `cert-manager`, created 18:24:42Z |
| no `kube-system` objects | no `cert-manager` Role/RoleBinding/Lease in `kube-system` |
| leadership | `successfully acquired lease cert-manager/cert-manager-controller`; cainjector Lease `cert-manager-cainjector-leader-election` held |
| no denial | zero `managed-namespaces-limitation` lines in either component's logs |
| CA injection | cainjector `"Updated object"` (after transient optimistic-concurrency retries); `caBundle` **896 bytes** populated |
| check | release **`Creation complete after 2m13s`**; `startupapicheck` Job absent (`hook-succeeded`) |

**Qualified** — and it immediately exposed the next blocker (FND-0061 / INFRA-089), which is how
the next frontier was supposed to appear.
