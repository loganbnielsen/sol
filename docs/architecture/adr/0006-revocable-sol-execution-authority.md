# ADR 0006: Revocable Sol execution authority

- **Status:** Draft
- **Date:** 2026-10-08
- **Source:** operator decision (architecture review for #1302)
- **Related:** #1302, #1307, ADR 0002 (Sol owns the complete cloud-target
  lifecycle), ADR 0005 (Sol owns only its declared contract boundary)

## Context

Sol must be an abstraction users can leave without recreating their cloud
resources. Exporting Terraform text is insufficient: a stale Sol checkout must
also lose the authority to mutate a deployment after ownership is handed off.
Repository markers and state metadata cannot enforce this because an older
binary can ignore them.

The AWS and GCP provider configurations currently rely on ambient credentials.
Both clouds support provider-level role assumption or service-account
impersonation, and both remote-state backends have separate credential
configuration. Configuring those blocks alone is not a security fence: if the
routine source credential can mutate target resources or state directly, an
older Sol checkout can bypass the scoped identity and use ambient authority.

Bootstrap has a different authority boundary. A root cannot create the backend
where its own state must live, and it cannot assume an identity before that
identity exists. Bootstrap therefore remains a distinct privileged operation,
even when the user experience folds it into the first `sol deploy`.

## Decision

Sol's supported detach guarantee is **revocation of Sol's target-scoped
execution principals**. Routine Sol credentials must be assume-only: they may
assume or impersonate the scoped principals required for their operation, but
must not have direct target mutation or state mutation rights. Every normal
mutation must pass through the scoped principal configured at the relevant
provider or backend boundary.

The guarantee is intentionally bounded. An account owner can deliberately
regrant access or use administrative credentials. Sol cannot prevent an owner
from doing so; it can guarantee that the supported Sol principals have been
revoked and that the ordinary Sol source credential cannot bypass that
revocation.

### Authority boundaries

1. **Bootstrap authority is separate and privileged.** It creates or prepares
   the durable backend and target-scoped identities. It is used only during
   explicit setup, not ordinary target plan, deploy, or destroy. The first
   `sol deploy` may preview and confirm, then run this bootstrap step inline.
   The public `sol cloud bootstrap` lifecycle is removed. Confirmed installation
   removal remains separate because installation state and identities outlive
   a target.
2. **Provider credentials are scoped independently.** Each AWS or GCP Terraform
   provider must assume or impersonate the target execution identity. That
   identity is revocable and limited to Sol's declared target boundary.
3. **Backend credentials are scoped independently.** Each S3 or GCS backend
   operation must use a separately scoped state identity. It may access the
   required state objects and locking mechanism, but it must not inherit broad
   provider permissions. Handoff fences this identity separately from the
   provider identity.
4. **The source credential is assume-only.** AWS caller credentials may assume
   the allowed roles but cannot directly mutate target resources or state. GCP
   caller credentials may impersonate the allowed service accounts but cannot
   directly mutate target resources or state. A provider assumption block with
   a broadly privileged ambient caller does not satisfy this decision.
5. **Kubernetes access is separately revoked.** The handoff process removes
   Sol's target Kubernetes write access and verifies that the Sol execution
   principal can no longer use it.
6. **Markers are diagnostic.** A repo or state marker may warn a newer Sol
   checkout that ownership was transferred. It is not part of the enforcement
   guarantee and cannot authorize writes.

### Fresh-account seed path

The primary supported path is a user-provided, already-existing remote state
backend. The user supplies bootstrap authority to create the target identities
and routine assume-only credentials for subsequent work. The backend must exist
before the Terraform root that uses it is initialized.

If Sol supports provisioning into an account with no backend, it must document
an explicit seed path: bootstrap using temporary local state (or a separately
prepared seed backend), create the durable backend and scoped identities, then
migrate state into the durable backend while holding an exclusive state lock.
Temporary state must be verified at the destination before the seed copy is
retired. A root must never be expected to create its own backend. The user
provided backend remains the recommended path; the temporary-state route is a
fallback, not an implicit behavior.

### Detach and ownership transfer

Detach is an explicit, authorized handoff, separate from export. Export is
non-destructive and produces independently maintainable Terraform and
Kubernetes configuration. Detach transfers authority and state:

1. Stop new Sol operations for the target and acquire the relevant Terraform
   state locks.
2. Export editable configuration and transfer the locked state to the
   standalone owner's backend without placing sensitive state in source control.
3. Revoke Sol's provider execution principal, backend state principal, and
   Kubernetes access. Invalidate or deny already-issued cloud sessions where
   the cloud supports it. Confirm that the normal assume-only caller cannot
   write directly and cannot regain the revoked target authority.
4. With the standalone owner's credentials, run a plan and verify that it
   proposes no unintended changes or resource replacement.
5. Declare handoff complete only after revocation and the no-unintended-change
   plan are verified. Sol must not reconcile the detached target afterward.

State transfer and revocation are separate from configuration export. State
contains sensitive values and is transferred only through a locked, secure
state mechanism. Kubernetes manifests alone do not transfer operational
responsibility for image releases, secrets, certificates, or platform upkeep;
the export documents those responsibilities.

## Testable acceptance criteria

For both AWS and GCP:

1. A routine source credential can assume or impersonate the declared target
   identities, and direct cloud-resource mutations by that source credential
   are denied.
2. Terraform provider operations use the target execution identity; backend
   reads, writes, and locks use the separately scoped state identity.
3. Revoking the target provider identity prevents a stale supported Sol
   checkout from mutating target resources. Revoking the backend identity
   prevents it from reading or changing target state.
4. Handoff revokes Kubernetes write access and verifies denial for the Sol
   principal. A repo/state marker alone does not pass this criterion.
5. State migration is locked and leaves a standalone state that plans without
   unintended changes or replacements. The standalone owner can then update a
   resource without Sol.
6. A fresh-account deployment follows one of the documented seed paths and
   does not rely on a Terraform root creating its own backend.
7. An account owner can intentionally regrant access or bypass the boundary
   using administrator authority; documentation states this limit plainly.

## Consequences

- Role assumption and service-account impersonation are necessary but not
  sufficient. IAM policy on the routine source credential is part of the
  security contract.
- Provider and backend setup have separate identities and acceptance checks.
- Bootstrap remains a privileged boundary even though first-run setup is
  exposed through `sol deploy`.
- Export and detach have distinct safety and authorization semantics.
- The contract is identical across AWS and GCP; provider-specific mechanisms
  implement it without weakening the guarantee.

## Non-goals

- Preventing an account owner or administrator from regranting access.
- Treating a declaration or state marker as an access-control mechanism.
- Committing Terraform state or sensitive outputs into the exported project.
- Expanding Sol's ownership beyond its declared target contract.
