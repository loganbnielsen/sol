---
id: INFRA-045
type: bug
severity: high
title: The GCP provisioner's IAM role already grants Kubernetes API authority
source: provider-contract verification 2026-09-19 — internal/pipeline/audits/2026-09-19_provider_contract_verification.md
---

**Depends on:** None.

**Audit finding:** `internal/pipeline/audits/findings/FND-0001-gcp-provisioner-iam-kubernetes-authority.md`
(the durable evidence body; this ticket is its derived engineering work).

**Related:** ADR 0003 (lifecycle phases, authority and policy), HARDEN-003
(evidence identity), `docs/qualification/gcp-bootstrap-inventory.md`
(the GCP authority model and its lifecycle acceptance row),
`cli/platform/infra/gcp/main.tf`, `cli/platform/infra/base/platform_provisioner_rbac.tf`.

## The finding

Sol's GCP authority model is described as two separable layers: the provisioner
service account's Google IAM role is said to let it *reach* the cluster and
confer no Kubernetes authority, while the in-cluster boundary is said to be
Kubernetes RBAC — the temporary install-window `cluster-admin` binding, then the
steady-state scoped ClusterRoles.

That description is false, and it is false in a load-bearing place. Sol:

- grants the provisioner service account `roles/container.developer` at
  **project** level (`cli/platform/infra/gcp/main.tf:321-324`);
- asserts in the same file that the role "confers no Kubernetes authority by
  itself" (`cli/platform/infra/gcp/main.tf:254-255`);
- repeats the claim in the qualification inventory — "IAM establishes cluster
  discovery/credential access; Kubernetes RBAC establishes Sol authority"
  (`docs/qualification/gcp-bootstrap-inventory.md:302`);
- and treats the RBAC bindings in `platform_provisioner_rbac.tf` as the
  steady-state boundary.

The GCP provider contract says otherwise:

- *Authorize actions in clusters using role-based access control*: "To authorize
  an action, GKE checks for an RBAC policy first. If there isn't an RBAC policy,
  **GKE checks for IAM permissions**. In GKE, IAM and Kubernetes RBAC are
  integrated to authorize users to perform actions if they have sufficient
  permissions according to either tool."
- *Authenticate to the Kubernetes API server*: granting `roles/container.developer`
  "provides access to Kubernetes API objects inside clusters".
- The IAM role reference for Kubernetes Engine Developer states "Provides access
  to Kubernetes API objects inside clusters. Lowest-level resources where you
  can grant this role: Project", and lists the included permissions —
  `container.deployments.*`, `container.pods.*` (including `pods.exec`),
  `container.namespaces.*`, `container.jobs.*`, `container.replicaSets.*`,
  `container.daemonSets.*`, `container.configMaps.*`, `container.secrets.*`, and
  more.

## Why it matters

The provisioner holds continuous, **project-wide** Kubernetes write authority
through Google IAM, independent of the RBAC install window and independent of
the namespaced steady-state bindings: create/delete Deployments, Pods
(including `exec`), Namespaces, Secrets, ConfigMaps and Jobs — on every cluster
in the project, not only the target cluster. The claimed boundary is not merely
under-documented; it is not enforced. Concretely:

- an actual operation as the provisioner — create a Namespace or a Deployment
  with no RBAC policy granting it — is expected to succeed **via IAM**, so the
  "bounded, non-escalatable steady-state provisioner" acceptance row cannot be
  satisfied by the RBAC evidence alone. A `kubectl auth can-i` probe is the
  natural instrument, but the qualifier must first confirm the instrument
  reflects GKE's IAM authorizer (in `SubjectAccessReview`) before trusting it;
- the ADR 0003 / ADR 0002 separation ("the authority to install is not the
  authority to mutate ordinary application resources") is not real on GCP while
  this grant stands;
- a reader trusting the comment and the inventory would report the boundary as
  qualified when it is not — exactly the failure mode HARDEN-003 exists to
  prevent (an assertion that cannot fail is invisible in a green run).

The equivalent AWS identity does not have this property: EKS IAM does not confer
Kubernetes authority, and the AWS provisioner is bounded by its access entry and
RBAC. GCP is asymmetric with AWS here, and the asymmetry is currently hidden by
the incorrect claim.

## Remediation

1. Replace the predefined, project-level `roles/container.developer` on the
   provisioner service account with the minimum needed to **reach** the cluster:
   a custom role limited to cluster discovery/credential retrieval
   (`container.clusters.get`, `container.clusters.list`, and
   `container.clusters.connect` if the credential path needs it). In-cluster
   authority then comes only from Kubernetes RBAC. Impersonation stays scoped
   as it already is (`roles/iam.serviceAccountTokenCreator` on that one service
   account).
2. Correct the authority claim in `cli/platform/infra/gcp/main.tf:254-255` and
   in the lifecycle inventory's "Kubernetes access" row
   (`docs/qualification/gcp-bootstrap-inventory.md:302`) to state the actual
   GKE behaviour: RBAC is checked first and IAM is the fallback, so an IAM role
   *does* confer in-cluster authority.

The one thing that must **not** be done is keeping the broad grant while leaving
the claim that it confers no authority: if a deliberately broader role is ever
retained, it is a recorded, accepted residual with its own justification, not a
boundary.

## Acceptance criteria

- The provisioner's Google IAM role contains no `container.*` permission that
  maps to a Kubernetes write verb (create/update/patch/delete) on workload or
  namespace resources; the grant is reduced to cluster discovery/credential
  access.
- The code comment and `gcp-bootstrap-inventory.md` describe GKE authorization
  as RBAC-first with IAM fallback, and no longer claim the IAM role confers no
  in-cluster authority.
- An offline structural check fails if a `roles/container.developer`-class grant
  is reintroduced on the provisioner identity (or documents why a broader grant
  is intentional).
- The live GCP lifecycle qualification demonstrates the IAM path both ways as the
  provisioner: an actual operation that no RBAC policy permits (e.g. creating a
  Namespace or Deployment) succeeds against the current grant and is denied after
  the narrowed role. The probe is demonstrated capable of failing (HARDEN-003). If
  a `can-i`/`SubjectAccessReview` probe is used, it is itself validated against an
  operation known to be allowed or denied before its result is trusted.

## Out of scope

- The Cloud DNS / cert-manager solver gap (already recorded as the first
  remaining gap in `gcp-bootstrap-inventory.md`) and the partially-installed
  destroy gap (INFRA-042).
- Any change to the AWS provisioner model; its access-entry/RBAC boundary is
  unaffected and was independently confirmed during this verification.
- Whether GKE's IAM authorization can be disabled cluster-side. This ticket does
  not depend on that: the remediation removes the in-cluster permissions from the
  IAM grant rather than trying to switch the authorizer off.

**Demo/example coverage:** Not applicable — this is an identity/authority
configuration, not a user-facing surface.

**TypeScript parity:** No language-parity impact.

## Implementation record (2026-09-19)

Implemented on `codex/infra-045` without a provider run:

- replaced the project-level `roles/container.developer` binding with a
  target-named custom role containing only
  `container.clusters.get`, `list`, `getCredentials`, and `connect`;
- corrected the GCP root and inventory to state the real RBAC-first, IAM-fallback
  authorization model;
- added `internal/ci/test_gcp_provisioner_role.sh`, which proves the structural
  guard rejects both a restored predefined developer role and an injected
  workload-write permission.

Static/mechanism acceptance is complete. The before/after denied operation and
probe falsification remain evidence for the next GCP live qualification; this
implementation performed no live/provider operation.

## Landed (2026-09-20)

Merged in #376 (FND-0001). The project-level predefined `roles/container.developer` grant
is replaced by a custom role holding only `container.clusters.get`, `.list`,
`.getCredentials` and `.connect`; `check_gcp_provisioner_role.sh` and its mutation test
pin the four-item allowlist and reject the predefined role returning. The code comment and
the inventory's "Kubernetes access" row now state the real model (RBAC first, IAM
fallback).

**Outstanding (behavioural, FND-0001 stays `FIXED_UNQUALIFIED`):** GCP Attempt 5 must show
the platform stage still reaching the cluster with this narrowed role, and a
Kubernetes-object operation denied. The static guard can establish neither.
