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
