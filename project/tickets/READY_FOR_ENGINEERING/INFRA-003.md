---
id: INFRA-003
type: feature
severity: medium
source: OBS-034 discussion 2026-09-03
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
