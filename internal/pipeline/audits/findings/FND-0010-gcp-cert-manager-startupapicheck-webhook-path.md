# FND-0010 — GCP cert-manager: the `startupapicheck` failure is narrowed to the API-server → webhook path

- **Classification:** `VERIFIED_DEFECT` — the platform apply failed because the Helm
  provider's default `timeout` cut off cert-manager's own post-install readiness check
  (established 2026-09-26 from Attempt 9's product log + the pinned chart upstream; see
  *Cause established* below). The API-server → webhook *reachability* branch this finding
  opened with is refuted: the x509 proves the API server reached the webhook.
- **State:** `FIXED_UNQUALIFIED` — the remedy (give the release the check's own designed budget) is
  implemented, and Attempt 10 **validates it live in the only sense it claims**: the release no
  longer cuts the check short and `startupapicheck` received its full 10-minute polling window
  (601s of polls, 15:17:28 → 15:27:29). It does **not** demonstrate successful cert-manager
  readiness or TLS trust — the check still failed, because the CA bundle was never injected. That
  remaining chain is FND-0060, and its fix is `INFRA-088`; no qualification is claimed here until a
  run shows the check **Succeed** and the install continuing.
- **First identified:** 2026-09-19 (GCP Attempt 4; analysed in this pass)
- **Last verified:** 2026-09-26, `main @ 3d3eb0aa`, from the Attempt 9 evidence bundle
- **Provider:** GCP / GKE (Autopilot, private nodes)
- **Derived ticket:** none yet — a ticket follows only if Attempt 5 confirms reachability
- **Related invariant:** `INV-SUBSTRATE-1`, `INV-PREREQ-1`
- **Related:** `HARDEN-004`, `internal/qualification/gcp/gcp-bootstrap-inventory.md` (Attempt 4 + remaining gap 1), FND-0007

## The observed failure

Attempt 4's platform-prerequisites apply stopped at `helm_release.cert_manager`:
`failed post-install: timed out waiting for the condition`. cert-manager itself
was healthy — `cert-manager`, `-cainjector`, `-webhook` all `1/1 Running`, six
CRDs installed — and the chart's `startupapicheck` Job showed `Failed 0/1` after
7m49s with `BackoffLimitExceeded`. The failing object is the post-install check,
and it is the only signal about whether the webhook is reachable.

## What the check actually does (verified from chart + source)

Chart `v1.14.4` at `cli/platform/infra/base/main.tf:147-158`, with no
`startupapicheck` override, so the defaults apply. `pkg/util/cmapichecker`
performs a **dry-run create of a `v1` `Certificate` in the `cert-manager`
namespace**, which the API server must validate by calling the **cert-manager
validating webhook**; `cmd/ctl/pkg/check/api` polls every 5s for `--wait=1m`
(chart `timeout: 1m`, `backoffLimit: 4`) and then exits non-zero. Four attempts
at ~1 m plus backoff ≈ the observed 7m49s.

The check's own doc comment says it creates a `v1alpha2` Certificate "to ensure
the API server has also connected to the cert-manager conversion webhook", but
that comment is **stale** in v1.14.4: the Certificates CRD serves only `v1` and
declares no `conversion` strategy. So the check exercises the **validating
webhook**, not conversion.

## Two popular explanations that do not survive verification

- **"Missing `seccompProfile: RuntimeDefault`."** False for v1.14.4: the chart
  sets it on all four components (`controller`, `webhook`, `cainjector`,
  `startupapicheck`). Three of those pods ran.
- **"Autopilot rejects the pod because it has no resource requests."** Not a
  discriminator: v1.14.4 sets `resources: {}` on **all four** components, and the
  webhook/controller/cainjector pods ran.

Both are widely cited; both are refuted by the chart's own defaults plus the
observed healthy siblings. Recorded here so the next attempt does not spend a
run on either.

## Why this is GKE-specific

The same chart, version and values reach `Ready` on EKS. So the difference is the
GKE control-plane → webhook path, not the chart configuration.

GKE's private-cluster documentation (verified at
`https://cloud.google.com/kubernetes-engine/docs/how-to/private-clusters`, the
"admission webhooks" firewall section) states that the control-plane firewall
rules allow traffic to nodes and Pods on *the ports the rules allow*, not to
Service ports, and that "Kubernetes features that require additional firewall
rules include: **Admission webhooks**, Aggregated API servers, **Webhook
conversion**, Dynamic audit configuration. Generally, any API that has a
ServiceReference field requires additional firewall rules."

cert-manager's webhook is a Service on port 443 whose pod/container port is
**10250** (`svc/cert-manager-webhook` `targetPort`), which is exactly the case
that documentation describes. Sol's GCP cloud root creates **no firewall rule**
(`cli/platform/infra/gcp/` has no `google_compute_firewall`), so the only rules
in play are GKE's defaults.

## Leading hypothesis (to confirm — not assumed)

The GKE control plane cannot reach the cert-manager webhook's **pod** port, so
the dry-run `Certificate` create is rejected for the whole 1-minute window on
every attempt, producing `BackoffLimitExceeded`. This is consistent with every
observation, but it is **not proven**: the discriminator is the check container's
own output, which Attempt 4 did not capture, and no bundle in the tree contains
it.

## The probe that decides it (run inside GCP Attempt 5)

Before the platform-prerequisites apply gives up:

- `kubectl -n cert-manager logs job/cert-manager-startupapicheck --all-containers`
  — the container's own output (the check runs with `-v`):
  - a webhook-call failure, `context deadline exceeded`, or a dial timeout to
    `...svc:443` / `:10250` → the reachability hypothesis is confirmed;
  - `x509: certificate signed by unknown authority` → the webhook CA bundle is
    not injected (`cmapichecker.ErrWebhookCertificateFailure`) — a different
    cause with a different fix;
  - `no matches for kind "Certificate"` → CRDs not served (unlikely; six were
    installed).
- `kubectl -n cert-manager get events --sort-by=.lastTimestamp` and
  `describe job` → distinguish a Pod that never ran (`FailedCreate`, admission)
  from one that ran and failed.
- `kubectl -n cert-manager get svc cert-manager-webhook -o jsonpath='{.spec.ports[*].targetPort}'`
  → confirm the pod port (expect 10250).
- `gcloud compute firewall-rules list --filter="name~<cluster>"` alongside the
  cluster's `masterIpv4CidrBlock` → whether any rule permits the master CIDR to
  that port.

## If confirmed

The fix is Sol-owned and small: a `google_compute_firewall` in the GCP cloud root
allowing the master CIDR to the webhook's **pod** port on the cluster's node
network — GKE's own documentation names this as the required step. Disabling
`startupapicheck` is not a fix: it discards the only signal that the webhook is
reachable, which certificate issuance depends on (recorded in
`gcp-bootstrap-inventory.md`). On confirmation this becomes a `VERIFIED_DEFECT`
and gets a ticket; until then it is a root-cause gap, not a defect claim.

## What is NOT established

- The actual log line, and therefore which branch above holds.
- Whether GKE's default master rule already permits pod port 10250 — the reason
  this is a hypothesis and not yet a defect.

## Supersession

None.


## Cause established (2026-09-26, from Attempt 9's own evidence)

**FACT (product log).** Attempt 9's `platform-prerequisites-apply` ended:

```
module.platform.helm_release.cert_manager: Still creating... [6m40s elapsed]
Warning: Helm release "" was created but has a failed status...
Error: failed post-install: 1 error occurred:
	* timed out waiting for the condition
  with module.platform.helm_release.cert_manager,
  on ../../modules/platform/main.tf line 148, in resource "helm_release" "cert_manager"
```

**FACT (the arithmetic lines up to the second).** The chart's post-install hook Job
`cert-manager-startupapicheck` was created at `01:52:46Z`; the apply failed at ~`01:57:41Z`
— 300 s later. The Helm provider's `timeout` defaults to **300 s** and bounds *that hook's
wait* as well as the main install. So Terraform gave up on a check that cert-manager
designed to keep polling (chart defaults: 4 attempts x 1 m, ~7m49s — the same shape Attempt
4 recorded as `BackoffLimitExceeded` after 7m49s).

**FACT (what the check was waiting for).** The captured `startupapicheck` log shows the
check polling every 5 s for exactly its 1 m budget and reporting

```
Internal error occurred: failed calling webhook "webhook.cert-manager.io": ...
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

and the captured `ValidatingWebhookConfiguration` had **no `caBundle`** and
**`generation: 1`** — i.e. it had never been updated — while all three cert-manager
Deployments (`cert-manager`, `-webhook`, `-cainjector`) were `1/1 Running` for 6m39s.

**FACT (upstream, chart `v1.14.4`).** The `webhook` pod runs with
`--dynamic-serving-ca-secret-name=cert-manager-webhook-ca`, so the pod writes the CA Secret
itself; the webhook configuration carries
`cert-manager.io/inject-ca-from-secret: cert-manager/cert-manager-webhook-ca`, which
**cainjector** copies into `caBundle`. No `certificate`/`issuer` CR participates, so the
"CR needs the webhook that needs the CR" deadlock does not exist here.

**Refuted branch.** The finding opened on a *GKE private-cluster firewall* hypothesis for
the control plane → webhook path. An `x509: certificate signed by unknown authority` from
the API server means the connection **succeeded** and the certificate could not be verified
against the (empty) `caBundle`, so reachability is not the failure. No firewall rule is
warranted, and the attempt that was planned for it would have found nothing.

**INFERENCE (not established).** Whether the CA/`caBundle` convergence would have completed
inside cert-manager's own budget (~7m49s) had Terraform let the check run: the check was cut
off at 300 s while it was still polling, so no attempt has yet shown the webhook becoming
usable within that window. The next attempt's widened discriminator (below) is what settles
it — if it still fails, that is a *different* finding (injection never converging) with its
own evidence, not this one.

## The fix (2026-09-26)

`platform/cloud/modules/platform/main.tf`, the single cert-manager `helm_release` shared by
both providers:

| setting | before | after | why |
|---|---|---|---|
| `timeout` | unset (provider default 300 s) | `1800` | the wait must outlast the check, not cut it short |
| `startupapicheck.timeout` | unset (chart default `1m`) | `10m` | one continuous poll window instead of a 1-minute attempt; the check still polls every 5 s and returns the moment the webhook answers |
| `startupapicheck.backoffLimit` | unset (chart default `4`) | `1` | keeps the worst case (2 x 10 m) inside the release bound |
| `wait` | unset (provider default `true`) | `true` stated | the chart's resources must be ready before its check runs; stating it keeps a future default change from silently disabling the gate |

The check stays **enabled**: it is cert-manager's own readiness contract and the only signal
that the webhook is usable, and every certificate-bearing component after cert-manager
depends on it. `atomic` is deliberately not set, so a failure leaves the release in place —
the shape FND-0058's qualification covers.

**Executable evidence (`internal/ci/check_cert_manager_readiness.sh`, wired into CI):** the
guard pins enabled check, a per-attempt budget >= 300 s, an explicit retry bound, and
`release timeout > (backoffLimit + 1) x per-attempt`, plus `wait = true` and CRDs from the
chart. Its mutation self-test
(`internal/ci/test_cert_manager_readiness_check.sh`) rejects eight mutations — including
**the pre-fix configuration itself** — and accepts the unmutated tree.

**Behavioural evidence (`internal/ci/test_cloud_lifecycle_offline.sh`):** the per-phase
failure loop already fails the install on a `prerequisites` (the cert-manager install) or
`crds` (cert-manager's API surface) failure; it now also asserts that the full platform
apply did **not** run after such a failure. Bypassing the CRD gate (a mutant whose
`await_crds` always reports success) fails the suite.

## What the next attempt must show

`internal/qualification/gcp/live-qual.sh`'s discriminator was widened (2026-09-26) to
capture what the first version could not: the CA and TLS Secrets (metadata and key names
only, never key material), the controller/webhook/cainjector logs, and the
`certificate`/`issuer` objects. A confirming attempt must show the `startupapicheck` Job
**Succeeded**, the platform apply continuing past cert-manager, and — if it reaches that far
— `Ready`, with the release's own wait no longer the limiting factor.

## Supersession

None. The reachability branch recorded above is refuted rather than superseded, and the
classification it produced (`QUALIFICATION_GAP`) is replaced by `VERIFIED_DEFECT`.

## Live evidence — GCP Attempt 10 (2026-09-26, `main @ bc9062b0`)

The fix was exercised live, and **the failure it addresses did not reproduce**:

- the release was still waiting at **9m20s**, where the pre-fix runs aborted at 414s, so the
  release never cut the check short;
- the check's own output is `error: timed out waiting for the condition`, and **no `x509` line
  appears anywhere in the 286-file bundle** — the pre-fix signature is absent from this specimen;
- the check's Job ended `BackoffLimitExceeded` after its own attempt window expired while its pod's
  container was still not started (the check pod's container started ~9½ minutes after its image
  was pulled), which is FND-0060's subject rather than this one's.

**State stays `FIXED_UNQUALIFIED`.** What the confirming attempt asked for — the Job **Succeeded**,
the platform apply continuing past cert-manager, `Ready` — did **not** happen: the platform still
failed at this boundary, for a different reason. Nothing here shows TLS trust was ever usable
(the CA Secret was populated, but the bundle has no injected `caBundle` and no successful check
run), so the remedy remains unexercised to a successful conclusion. The blocker is now FND-0060 /
INFRA-087.

## Root cause established — Attempt 10 forensic re-analysis (2026-09-26)

Attempt 10 (`main @ bc9062b0`) exercised the remedy live and produced the evidence that names the
real cause. The remedy worked as designed and was not the limiter: the release waited, and
cert-manager's own check ran its full window.

**The chain (all facts from the frozen bundle, `/tmp/sol-gcp-qual-10`):**

1. The chart is installed with its default `global.leaderElection.namespace` = **`kube-system`**
   (the chart's own `values.yaml`; `templates/rbac.yaml` and the two deployment templates create the
   leader-election `Role`/`RoleBinding` there and pass `--leader-election-namespace` to both
   components).
2. GKE Autopilot **denies** that write: `GKE Warden authz [denied by managed-namespaces-limitation]:
   the namespace "kube-system" is managed and the request's verb "create" is denied` — 30 attempts
   each, controller 15:16:46 → 15:27:59, cainjector 15:16:38 → 15:27:43. Neither ever led.
3. With cainjector unable to lead, the `ValidatingWebhookConfiguration` (created 15:15:47Z) has
   **no `caBundle` field at all**.
4. The webhook therefore failed its clients' TLS — `http: TLS handshake error … remote error: tls:
   bad certificate` — as the check polled: **122 lines, every ~5s, 15:17:28 → 15:27:29 (601s)**.
5. The check printed `error: timed out waiting for the condition`; the Job (`backoffLimit: 1`, pod
   `restartPolicy: OnFailure`, `activeDeadlineSeconds` unset, startTime 15:16:59Z) recorded one
   failure, the kubelet restarted the container, and the Job deleted the pod and moved to
   `BackoffLimitExceeded` (15:27:29Z/15:27:31Z).

**So the earlier reading of this finding was a symptom, not the cause.** The "TLS trust not ready"
that Attempts 4/5/8/9 showed is what a never-injected `caBundle` looks like from the client side;
the reason it was never injected is the leader-election namespace. The budget remedy was still
necessary (Attempt 9's 300s provider timeout cut the check at 414s, before it could even exhaust
its own window), and Attempt 10 proves it landed: the check got its full 600s.

**Fix proposed in `INFRA-088`** (now the finding FND-0060): set `global.leaderElection.namespace`
to the release namespace in `helm_release.cert_manager` (one declared value), with a guard over the
module and a discriminating live run (leases acquired in `cert-manager`, `caBundle` populated, check
Job Succeeds). No live mutation without separate authorization.

**This finding's own claim, kept narrow:** the budget remedy works as designed and Attempt 10 shows
the check getting that budget. Whether cert-manager becomes *ready* — the thing the check exists to
establish — is not yet demonstrated by any run, and this finding is not qualified until one shows
it.

**Falsified in this pass:** `FND-0060` (the ~9½-minute "scheduling delay" reading of the same run).
