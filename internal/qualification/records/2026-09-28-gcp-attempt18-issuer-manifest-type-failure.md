# GCP qualification Attempt 18 (2026-09-28) — the DNS-01 wiring failed at the first apply, on a manifest type error

## Summary

| | |
|---|---|
| revision | `a0209b46` (`DEC-055`: the provider-native DNS-01 path, plus Workload Identity enabled) |
| target | fresh `qual18/gcp/us-central1`, cluster `sol-qual-gcp-18`, 4 × e2-standard-4, **`cluster_issuer: letsencrypt-staging`** declared |
| what worked | the target was accepted (the GCP install-time refusal this change lifted is gone), the substrate came up, the platform prerequisites applied |
| result | **the platform apply failed in 36 s** on the ClusterIssuer manifests, before cert-manager saw them |
| immediate cause | `Error: Failed to transform Tuple element into Tuple element type … object.spec.acme.solvers[0]` |
| consequence | the **destroy also failed** on the same error, leaving the substrate standing until the module was fixed |
| fix | the solver is no longer built from a provider-conditional local; each provider has its own gated, literal ClusterIssuer resources |
| evidence bundle | `/tmp/sol-gcp-qual-18` |

## 1. Identity

| Field | Value |
|---|---|
| revision | `a0209b46` (`harness.log` line 1) |
| target | `qual18/gcp/us-central1`, `sol-qual-gcp-18`, `letsencrypt_email: qualification@sol-harden-qualification.dev`, `cluster_issuer: letsencrypt-staging` |
| timings (UTC) | started `04:43:39Z`; credentials established `04:51:15Z` (poll 47); `terraform-apply ok (776.7s)`; `platform-prerequisites-apply ok (50.9s)`; **`platform-apply FAILED (36.0s)`** |
| preflight | clean (no clusters or SQL instances, `SSD_TOTAL_GB 0/1000`, both durable prerequisites present) |

## 2. What happened

The run got further than any before it in one respect and *stopped* in another:

- **The lifted gate is live.** The driver accepted a GCP target that declares `cluster_issuer` — the
  refusal that existed until `DEC-055` would have stopped the run here with
  *"Sol cannot yet wire a certificate issuer on GCP"*. The target file carries
  `cluster_issuer: letsencrypt-staging`, and the run proceeded to the platform.
- The substrate and the prerequisites applied, and then:

```text
[platform-apply] FAILED (36.0s)
  │ Error: Failed to transform Tuple element into Tuple element type
  │   with module.platform.kubernetes_manifest.letsencrypt_prod,
  │   on ../../modules/platform/cert_manager_issuer.tf line 74, in resource "kubernetes_manifest" "letsencrypt_prod":
  │ Error (see above) at attribute: object.spec.acme.solvers[0]
  │ Error: Failed to transform Object element into Object element type
  │   at attribute: object.spec.acme.solvers
```

This is Terraform's `kubernetes_manifest` provider converting the HCL value against the CRD's schema. My
change had moved the solver from an inline literal (`solvers = [{ dns01 = { route53 = { … } } }]`, which
applied cleanly in Attempts 16 and 17) into a **conditional local**, and the two branches have different
object types — `{ cloudDNS = { project = … } }` and `{ route53 = { region = …, roleArn = … } }`. The
unified type the conditional produces is not something the provider's schema conversion accepts.

Because the same config is read when the resource is refreshed, **`sol cloud destroy` failed on the same
error**: the platform root could not be planned, so the supported destruction could not converge the
target. The harness reported `teardown NOT verified: resources remain` and kept the target file, which is
its designed behaviour. The cluster, its SQL instance and 400 GiB of disk quota stayed standing.

## 3. Fix

`platform/cloud/modules/platform/cert_manager_issuer.tf` no longer builds a solver from a conditional.
Each provider gets its own two ClusterIssuer resources — a staging and a production one — each carrying a
**literal** manifest of exactly the shape that already applied, gated by `count = var.cloud_provider == …`
so only the provider's pair exists, and each with a `precondition` refusing an empty identity for that
provider. That keeps every value the provider `kubernetes_manifest` sees structurally identical to the
configuration that worked, and it puts each provider's solver in one readable place.

`check_provider_tls_path.py` was strengthened to match: each provider must have **two** issuers carrying
its solver, each taking its scope from that provider's variable, each refusing an empty identity, and each
gated on the provider — plus a mutation for every one of those (16 in total).

## 4. Recovery, and what it cost

The destroy could not run under the broken configuration, so the target was converged with Sol's supported
destroy **from the fixed revision** — no manual provider action, no state surgery. The runner: the fix was
made and validated first, then `live_qual.sh destroy` ran against the existing target and the harness
verified absence in the usual way.

The failure cost one specimen and about 25 minutes of a 4-node substrate, and it is a genuine defect in
the change rather than a substrate or provider problem: the same conditional-local pattern would have
failed on AWS for the same reason.

## 5. What this run establishes

- The GCP driver **does** accept a target that declares `cluster_issuer` (the lifted gate, observed).
- The revocation **of the earlier refusal** did not break the substrate path: bootstrap, cloud apply and
  the platform prerequisites all passed with the new cluster configuration (Workload Identity enabled).
- It does **not** establish the TLS path: the issuers were never created, so no challenge was attempted and
  no certificate was requested. The next specimen is the one that asks that question.
