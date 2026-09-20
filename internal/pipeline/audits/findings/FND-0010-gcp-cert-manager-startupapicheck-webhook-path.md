# FND-0010 — GCP cert-manager: the `startupapicheck` failure is narrowed to the API-server → webhook path

- **Classification:** `QUALIFICATION_GAP` — the *cause* is not yet established
- **State:** `OPEN` — desk analysis complete; confirmation needs the Attempt 5 container log
- **First identified:** 2026-09-19 (GCP Attempt 4; analysed in this pass)
- **Last verified:** 2026-09-19, `main @ 7e79df49`
- **Provider:** GCP / GKE (Autopilot, private nodes)
- **Derived ticket:** none yet — a ticket follows only if Attempt 5 confirms reachability
- **Related invariant:** `INV-SUBSTRATE-1`, `INV-PREREQ-1`
- **Related:** `HARDEN-004`, `docs/qualification/gcp-bootstrap-inventory.md` (Attempt 4 + remaining gap 1), FND-0007

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
