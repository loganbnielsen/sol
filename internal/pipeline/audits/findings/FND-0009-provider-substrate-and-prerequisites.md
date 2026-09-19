# FND-0009 — Provider substrate and host-prerequisite differences

- **Classification:** `OBSERVATION`
- **State:** `OPEN` (AWS storage/prereqs qualified; GCP storage and plugin preflight mechanism-only)
- **First identified:** 2026-09-19 (this pass; consolidates known evidence)
- **Last verified:** 2026-09-19, `main @ 910a59f1`
- **Providers:** AWS and GCP
- **Derived ticket:** none
- **Related invariant:** `INV-SUBSTRATE-1`, `INV-SUBSTRATE-2`, `INV-PREREQ-1`

This finding consolidates three provider-difference topics the audit model must
keep visible. None is a defect.

## 1. Platform storage is provider-realized, not shared

- **AWS.** EKS ships no default StorageClass. Sol installs the EBS CSI addon with
  a scoped IRSA role and creates a `gp3` default class
  (`WaitForFirstConsumer`, encrypted). HARDEN-002 finding 7; qualified live in
  Run 5 Attempt 5 (PVCs bound, Redpanda 3×2/2, readiness asserts the class + CSI
  driver).
- **GCP.** GKE ships `standard-rwo` (`pd.csi.storage.gke.io`), already annotated
  default; Sol creates no class and adopts it. `create_storage_class = false`.
  The inventory records GCP StorageClass presence; a *bound persistent workload*
  has not been qualified because Attempt 3 never reached readiness.
- **Workload declaration.** A workload-scoped persistent volume is `single`-tier
  only (DEC-026 §3); secret volumes must not be mistaken for it (DEC-029). This
  is provider-neutral and unaffected by the storage mechanism.

## 2. Host toolchain prerequisites differ

- **GCP.** The kubeconfig `gcloud` writes names `gke-gcloud-auth-plugin` as its
  client-go exec plugin; without it every Kubernetes call fails. Attempt 3 hit
  this *inside* the platform apply, after GKE and Cloud SQL were billable. Sol
  now checks it before the first platform call and fails closed
  (`cmd_cloud_tf.ml:712-728`). The check itself has not been exercised live.
- **AWS.** The `aws` CLI is used by credential resolution and
  `eks update-kubeconfig`; a missing CLI fails at credential resolution before
  the billable apply. There is no dedicated `aws --version` preflight.
- **Common.** Terraform is a hard prerequisite in the same class.

## 3. Provider differences are explicit, not hidden

The separate `base-gcp` root (GCS backend, module call into `base`), the
provider-specific output/input contract, and the inventory's "AWS assumptions
not to carry into GCP" list are deliberate. The invariant is that the *capability*
is shared, not the mechanism.

## What is established

AWS platform storage is behaviourally qualified. GCP storage is wired but not
behaviourally exercised past install.

## What is NOT established

- A GCP persistent platform workload binding to the adopted default class.
- The `gke-gcloud-auth-plugin` preflight firing on a host that lacks the plugin.
- A GCP absence check for EBS-equivalent orphaned disks (the AWS EIP/NAT/EBS
  sweep gap is recorded in FND-0003).

## Why no ticket

These are parity/qualification rows owned by the provider agents; no concrete
defect is established. The AWS preflight absence is a minor asymmetry, not a
demonstrated failure (credential resolution already fails closed first).

## Supersession

None.
