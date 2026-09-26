# FND-0001 — GCP provisioner IAM role grants Kubernetes API authority

- **Classification:** `VERIFIED_DEFECT`
- **State:** `FIXED_UNQUALIFIED` — the narrowed role and its guard landed in #376; a live run must still confirm the platform stage reaches the cluster with it and that a Kubernetes-object operation is denied
- **First identified:** 2026-09-19 (provider-contract verification pass)
- **Last verified:** 2026-09-19, `main @ 910a59f1`
- **Provider:** GCP / GKE
- **Derived ticket:** **INFRA-045** (`internal/pipeline/tickets/DONE/INFRA-045.md`)
- **Related invariant:** `INV-AUTH-2`, `INV-AUTH-4`
- **Related decisions:** ADR 0002 (identity table), ADR 0003 (invariant 2)
- **Governing report:** `../2026-09-19_provider_contract_verification.md`

## Sol claim at stake

The GCP root presents the provisioner service account's Google IAM role as
letting it *reach* the cluster and conferring **no** Kubernetes authority, with
in-cluster authority established solely by Kubernetes RBAC:

> `#   * roles/container.developer is what lets it *reach* the cluster (fetch`
> `#     credentials and read the cluster), and it confers no Kubernetes authority`
> `#     by itself;`
> — `cli/platform/infra/gcp/main.tf:254-255`

The qualification inventory repeats the claim:

> "IAM establishes cluster discovery/credential access; Kubernetes RBAC
> establishes Sol authority." — `internal/qualification/gcp/gcp-bootstrap-inventory.md`,
> §"Proposed GCP capability mapping", row "Kubernetes access"

ADR 0003 invariant 2 states the steady-state provisioner "cannot manufacture a
more powerful identity"; the production matrix row I3 states the boundary is
that "the provisioner cannot manufacture an identity more powerful than itself".

## Verified provider contract

- GKE authorizes **RBAC first, then IAM**:
  "To authorize an action, GKE checks for an RBAC policy first. If there isn't an
  RBAC policy, GKE checks for IAM permissions. In GKE, IAM and Kubernetes RBAC
  are integrated to authorize users to perform actions if they have sufficient
  permissions according to either tool."
  — https://cloud.google.com/kubernetes-engine/docs/how-to/role-based-access-control
- `roles/container.developer` "Provides access to Kubernetes API objects inside
  clusters. Lowest-level resources where you can grant this role: Project" and
  includes `container.deployments.*`, `container.pods.*` (incl. `pods.exec`),
  `container.namespaces.*`, `container.secrets.*`, `container.configMaps.*`,
  `container.jobs.*`, `container.replicaSets.*`, `container.daemonSets.*`.
  — https://cloud.google.com/iam/docs/roles-permissions/container
- The GKE authentication page likewise says granting `roles/container.developer`
  "provides access to Kubernetes API objects inside clusters".
  — https://cloud.google.com/kubernetes-engine/docs/how-to/api-server-authentication

## Current implementation evidence

- `cli/platform/infra/gcp/main.tf:321-324` grants the provisioner service
  account `roles/container.developer` at **project** level
  (`google_project_iam_member.provisioner_cluster_access`).
- The same identity is the steady-state platform provisioner bound by RBAC in
  `cli/platform/infra/base/platform_provisioner_rbac.tf`
  (`kubernetes_cluster_role_binding.platform_provisioner_cluster_gcp`,
  `kubernetes_role_binding.platform_provisioner_gcp`).
- The temporary install window is a separate object
  (`kubernetes_cluster_role_binding.provisioner_bootstrap_admin`,
  `gcp/main.tf:284-300`), opened and closed by `provisioner_bootstrap_admin`.

## Evidence available

| Tier | Evidence |
|---|---|
| STATIC | the project-level role grant and the claim in the same file; the RBAC bindings |
| MECHANISM | GCP Attempt 3 showed the provisioner impersonation works and the install-window binding is revoked on the failure path (`provisioner-bootstrap-access-remove` ok, 8.7 s) — `gcp-bootstrap-inventory.md`, §"Attempt 3 (2026-09-19)" |
| BEHAVIORAL | **none for the boundary.** No run has demonstrated a workload operation being *denied* to the provisioner after closure; the IAM path would in fact permit it |

## What is established

The provisioner service account holds continuous, project-wide Kubernetes write
authority through IAM — create/delete Deployments, Pods (incl. `exec`),
Namespaces, Secrets, ConfigMaps and Jobs on every cluster in the project —
independent of the RBAC install window. The install-window RBAC binding is not
the boundary the design claims it is.

## What is NOT established

- The exact live severity was not measured (no run attempted the operation).
- A `kubectl auth can-i` probe is *not* assumed to surface GKE's IAM authorizer
  in `SubjectAccessReview`; the qualifier must validate the instrument first
  (HARDEN-003).
- Whether a custom, narrower IAM role is sufficient for `get-credentials` +
  impersonation was not tested live.

## Impact

The authority model's central claim is false on GCP. A reader trusting the code
comment and the inventory would report the boundary as qualified when it is not,
which is the failure HARDEN-003 exists to prevent.

## Derived engineering work

- **INFRA-045** (created by this finding): replace the project-level predefined
  role with a custom role limited to cluster discovery/credential retrieval, and
  correct the two claims.

## Relationship to the external research packet

The packet claimed the same falsehood ("`roles/container.developer` … does not
natively authorize workload deployment"). The packet is not the source of the
finding; the primary sources are. See `../research/aws-gcp-harden-research_gemini-external.md`.
