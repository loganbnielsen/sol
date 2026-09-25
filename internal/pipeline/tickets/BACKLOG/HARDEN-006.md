---
id: HARDEN-006
type: verification
severity: high
title: GCP qualification attempt 8 — the cert-manager startupapicheck discriminator (Ready if it does not reproduce)
source: docs/qualification/README.md (the run that replaces the HARDEN-004 epic's frontier)
---

**Depends on:** INFRA-076.

**Related:** HARDEN-004 (closed epic), FND-0010, FND-0007, FND-0029, DEC-042, DEC-043,
`internal/qualification/gcp/live-qual.sh` (the harness this run drives).

## Blocked On

Explicit operator authorization for a live, billable GCP run, and a fresh Phase-0 read-only
baseline of `sol-qualification`. Promote to `READY_FOR_ENGINEERING` only when both exist.

## Goal

Reach the cert-manager boundary of a platform install on a disposable GCP target and **establish the
cause** of the post-install `startupapicheck` failure the earlier attempts stopped at (FND-0010),
from the check's own output and the surrounding cluster evidence, classified against the candidate
causes. Reaching platform `Ready` is the alternate success outcome: if the cause does not reproduce,
the run establishes that the GCP platform now installs to `Ready`, which no attempt has done.

The boundary itself is not in doubt and is not this run's question. Attempts 3–6 and the 2026-09-25
re-baseline agree: cert-manager's own pods are healthy, the chart's post-install check fails, and the
check is the only signal about whether the API server can reach the validating webhook. Disabling
the check so the release passes is explicitly **not** the fix, and this run adds no firewall rule: it
captures evidence, classifies it, and stops. Remediation is a separate authorization.

Re-scoped 2026-09-25 by the re-baseline's H1–H6 (prepared in the harness, not launched): the
discriminator comes first, because every downstream GCP row waits on this boundary and the previous
harness could not observe the failure it existed for.

## Why it depends on INFRA-076

Until Terraform is supervised so that Sol's death cannot kill it with SIGPIPE, a live run can
reproduce the only known Sol-caused provider/state divergence. That fix has landed (`DONE`).

## Acceptance criteria

- Run under the operating rules in `docs/qualification/README.md` (cost rule; `Absent`; process
  identity, not patterns; no force-unlock of a live lock; no signals to provider plugins) and the
  phase model in the harness header (`cloud` → discriminator or Ready evidence → freeze → `destroy`).
- The generated target declares **no** `cluster_issuer`: a GCP target that asks for one is refused at
  install time (FND-0007), which would stop the run before cert-manager.
- **The discriminator is captured before any teardown**, from a failed `sol cloud apply`: the check
  container's own log, the Job's status and description, Kubernetes events, the webhook Service's
  `targetPort` and endpoints, the webhook configuration, the cert-manager objects, the nodes, the GKE
  master CIDR and the cluster's firewall rules — and then **classified**, with the matched evidence
  quoted. `UNKNOWN` is an acceptable classification; an assumed cause is not, and a classification
  that contradicts the reachability hypothesis ends the run (it is the run's most valuable output).
- The evidence bundle contains, indexed by `evidence-manifest.txt`: Sol's own run artifacts (copied
  out of its 20-run pruning window), the Terraform state of both disposable roots, the pre-teardown
  provider inventory, the discriminator evidence and its classification, and the post-teardown
  provider inventory. The pre-teardown inventory is captured after the install outcome and before the
  teardown.
- Teardown through the supported path only (`sol cloud destroy --apply`), with the durable root and
  the delegated zone excluded by name (`create_dns_zone=false`), followed by an independent provider
  inventory: every disposable class ABSENT or a named approved retained item; the durable
  prerequisites PRESENT.
- A run record `docs/qualification/<date>-gcp-attempt8.md` from `run-record-template.md`, with each
  targeted matrix row qualified, blocked or not reached — each stated, and the classification quoted.
- `internal/pipeline/audits/QUALIFICATION_STATUS.md` updated.

## What this run does not do

- It does not qualify public TLS (`FND-0007` stays blocked), the application rows, the steady-state
  authority rows that need a `Ready` cluster beyond the cheap denied-write probe, retention with
  durable observability (`FND-0057`), or anything on AWS.
- It does not reproduce FND-0029's shape: that needs a target which *declares* an issuer to be applied
  and then destroyed unedited, which this run's target deliberately is not.
