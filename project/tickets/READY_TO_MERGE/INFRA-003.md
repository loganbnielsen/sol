---
id: INFRA-003
type: feature
severity: medium
source: OBS-034 discussion 2026-09-03
branch: INFRA-003/gcp-substrate-parity
worktree: ../sol-INFRA-003-gcp-substrate-parity
pr: https://github.com/loganbnielsen/sol/pull/159
---

Provider-specific substrate adapters for cloud integrations (identity binding, object storage, ...)

**Depends on:** None.

## Problem

`platform/infra/aws` implements provider-specific pieces that
`platform/infra/base` consumes through plain Terraform variables (IRSA role
ARNs, S3 bucket names, ECR registry URL, Route53 zone). `platform/infra/gcp`
only implements the always-needed baseline (VPC, GKE, Artifact Registry,
Cloud SQL, DNS) — it has no equivalent for durable-observability's identity
binding (AWS IRSA vs. GCP Workload Identity) or object storage (S3 vs. GCS).
OBS-034 makes that gap fail loudly (`cloud_provider` variable, `gcp` rejected
for `self_hosted_durable`) instead of silently, but doesn't build the GCP
side.

## Goal

When a real GCP-backed feature needs one of these contracts, there's a clear
place to add it — `platform/infra/gcp` grows the matching module (mirroring
`aws/`'s shape), and `base` keeps consuming it through the same kind of
cloud-agnostic variables it already uses today. No new abstraction layer
gets invented ahead of a concrete second implementation.

Known contracts likely to need this treatment, in roughly the order a real
GCP deployment would hit them:

- Identity binding: AWS IRSA vs. GCP Workload Identity (blocks `gcp` +
  `self_hosted_durable` today, per OBS-034)
- Object storage: S3 vs. GCS (Loki/Thanos buckets)
- Managed load balancer / Ingress annotations
- DNS / cert-manager provider hooks
- Secret/KMS integration, if Sun takes on managing that later

## Not in scope

A generic multi-cloud adapter interface or `cloud_provider`-branching helper
library. Build the GCP-side module for whichever contract a real feature
needs first, matching `aws/`'s existing shape; only generalize once a
second concrete case shows what's actually shared.

## Scope note (added at review)

This ticket delivered Layer 1 only: `platform/infra/gcp` now has the GCS +
Workload Identity module (`loki_gcs_bucket`, `loki_workload_identity_sa_email`,
`thanos_gcs_bucket`, `thanos_workload_identity_sa_email` — 1:1 with `aws/`'s
`loki_s3_bucket`/`loki_irsa_arn`/etc.), validated via `terraform fmt`/`validate`
(no live GCP account available to go further). It does **not** wire these
outputs into `platform/infra/base`, and does not touch
`platform/components/loki/values-durable.json`'s hardcoded `storage.type =
"s3"`/`object_store = "s3"` — doing that blind, without a live GCP cluster to
validate the Helm chart's GCS mode against, risked regressing the
currently-working AWS path. OBS-034's `cloud_provider` gate therefore still
rejects `gcp` + `self_hosted_durable` after this ticket — that's expected,
not a regression. The remaining wiring is tracked as [[INFRA-005]].

## Review — automated checks passed
GCS+Workload Identity module validated (terraform fmt/validate clean, no live GCP account needed for that), output shapes confirmed 1:1 with aws/'s S3+IRSA outputs; deliberate Layer-1-only scope now documented on the ticket, base-wiring follow-up filed as INFRA-005
