---
id: INFRA-005
type: feature
severity: medium
source: INFRA-003 review, 2026-09-08 — scope explicitly deferred, not an oversight
---

**Depends on:** INFRA-003 (done — the GCS + Workload Identity module this wires up).

Wire GCP's durable-observability outputs into `platform/infra/base`, and make Loki/Thanos Helm values provider-aware.

## Problem

INFRA-003 built `platform/infra/gcp`'s GCS + Workload Identity module (`loki_gcs_bucket`, `loki_workload_identity_sa_email`, `thanos_gcs_bucket`, `thanos_workload_identity_sa_email`), mirroring `platform/infra/aws`'s S3+IRSA shape 1:1. It deliberately stopped there: `platform/infra/base` doesn't consume these new outputs, and `platform/components/loki/values-durable.json` still hardcodes `storage.type = "s3"` / `object_store = "s3"`. As a result, OBS-034's `cloud_provider` gate still rejects `gcp` + `self_hosted_durable` after INFRA-003 — the GCP module exists but nothing routes to it yet.

**Why this was deferred rather than done in INFRA-003:** validating the Helm chart's GCS mode requires a live GCP cluster; this environment has no GCP credentials or cluster access, and guessing the Helm values wiring blind risked silently breaking it or, worse, regressing the currently-working AWS path if the conditional logic were wrong.

## Goal

- `platform/infra/base` accepts GCP's new outputs the same way it accepts AWS's today (plain variables — no new abstraction layer).
- `platform/components/loki/values-durable.json` (and the equivalent Thanos/Prometheus values, if separate) branch on provider to set `storage.type`/`object_store` to `gcs` when `cloud_provider == "gcp"`, without changing behavior for `cloud_provider == "aws"`.
- OBS-034's gate allows `gcp` + `self_hosted_durable` once this lands, assuming it's actually been validated to work — don't just remove the rejection without verifying against a real cluster.
- This needs an actual live GCP cluster to validate against (`sol cloud apply` targeting GCP, or an equivalent manual GKE setup) — not just `terraform validate`. Scope the verification pass accordingly; don't merge on Terraform-only validation for the Helm-values half of this change.

## Not in scope

Everything INFRA-003's own "Not in scope" section already excludes (generic multi-cloud adapter interface). This ticket is specifically about closing the loop INFRA-003 opened, not adding new contracts (load balancer/ingress, DNS/cert-manager, secrets/KMS) — those stay separate future tickets per INFRA-003's contract list.

## Blocked On

Live GCP cluster access to validate the Helm-values GCS wiring and then open
OBS-034's `cloud_provider` gate for `gcp` + `self_hosted_durable`. This
environment has no `gcloud` CLI and no GCP credentials at all.

## Progress notes (2026-09-14)

The plumbing half is done and merged (PR #252, `platform/infra/base/main.tf`
+ `variables.tf`): GCP's INFRA-003 outputs are now consumed the same
plain-variable way AWS's are, `loki_infra_bindings` /
`prometheus_thanos_server_fields` / `thanos_objstore_config` and the Thanos
Helm `set` blocks branch on `cloud_provider` to produce GCS-shaped config
(Workload Identity KSA annotations, `storage.type = "gcs"`, full
`objstore.yml`/schema-config overrides — Helm replaces these lists wholesale
rather than merging, so GCP needed its own complete list, not a patch of
AWS's) instead of a bare string swap. `terraform validate`/`fmt` pass on
`base`, `aws`, and `gcp`; the AWS branch of every touched block was verified
unchanged.

**Deliberately not done, and why this ticket is not `DONE`:** OBS-034's gate
still rejects `gcp` + `self_hosted_durable` — untouched on purpose. The
remaining work (an actual `sol cloud apply` against a real GCP cluster,
confirming Loki/Thanos actually come up against GCS, then flipping the
gate) needs GCP credentials and cluster access this environment does not
have. Moved to `BACKLOG` rather than left in `READY_FOR_ENGINEERING` so
`/work` doesn't try to pick it up again without that access — see Blocked
On above. When GCP access exists, the remaining task is "exercise this
against reality, fix anything discovered, then remove the gate," not
rediscovering the wiring.
