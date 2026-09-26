# ADR 0002: Sol owns the complete cloud-target lifecycle

- **Status:** Accepted
- **Date:** 2026-09-17
- **Scope:** AWS `production-single-region/v1`; provider boundary designed for later implementations

## Context

`sol cloud apply <target>` currently applies only `platform/cloud/aws/cluster` and
stops. A ready target also needs `platform/cloud/modules/platform`, including a staged
cert-manager apply because Terraform resolves `ClusterIssuer` kinds at plan time
before a same-apply CRD can exist. The only working orchestration is in
`internal/qualification/aws/live-smoke.sh`; the tutorial instead tells operators to run one
base-root apply, which fails on a fresh cluster.

The two Terraform roots also have unrelated local state by default. The AWS root
already exports the values the base root needs, but callers pass them by hand
(and the smoke script reconstructs one ARN). Bootstrap can create an encrypted,
versioned and locked S3 backend, yet Sol runs bare `terraform init` and relies on
an operator-created backend override. A lifecycle that resumes only on the same
machine is not a durable target lifecycle.

## Decision

The existing command is the public lifecycle boundary:

| Command | Contract |
| --- | --- |
| `sol cloud plan <target>` | Preview every currently plannable phase and report phases deferred by unavailable prerequisites. |
| `sol cloud apply <target>` | Reconcile the target through cloud substrate, platform substrate and verified readiness. |
| `sol cloud destroy <target>` | Prepare destruction, verify preparation, destroy both substrates in dependency order and verify absence. |
| `sol target show <target> --check` | Report live target readiness or a named, fail-closed unmet reason. |

No new `provision` or `cloud status` vocabulary is added.

### Planning is staged and non-mutating

`sol cloud plan` plans every phase whose lifecycle prerequisites currently
exist. A later phase that cannot yet be planned is reported as `Deferred` with
the concrete missing prerequisite; it is not reported as planned and is not a
production-readiness `Unmet` result. Planning never mutates infrastructure to
make another phase plannable.

For example, a fresh target can plan the cloud substrate while deferring the
platform prerequisites until the cluster exists, then defer the remaining
platform substrate until its CRDs are Established. Each successful apply makes
more of a later plan available.

Custom RBAC adds one explicit bootstrap boundary: when the cluster exists but
the provisioner has not yet established its steady-state RBAC, plan reports the
platform phases `Deferred` because granting temporary bootstrap access would be
a mutation. Apply grants that access for the bootstrap window and removes it
after the RBAC exists.

Exit status is defined as follows:

- zero: every currently plannable phase planned successfully; explicitly
  deferred later phases are allowed;
- non-zero: a phase that should be plannable failed, or target configuration,
  state, credentials or authentication are invalid or unavailable.

`Deferred` is plan-specific: Sol lacks enough established prior state to
compute that future plan. `Unmet` remains the readiness/preflight verdict that a
required capability is not established.

### State ownership and initialization

Each Terraform root owns its own resource state. Both states use the target's
durable backend facility but have separate, deterministic target-derived object
keys. Sol supplies runtime backend configuration to `terraform init`; it does
not generate or require a tracked `backend.tf` and does not rely on ambient local
state for the normal target lifecycle.

Bootstrap remains a deliberately separate boundary: it creates the durable
state facility because it cannot store its initial state in a facility that does
not exist yet. Bring-your-own conformant backends remain valid. After bootstrap,
the target declaration contains enough provider-neutral information for the
provider implementation to initialize both roots. Account-specific backend
configuration is runtime material, not repository source.

Terraform state is authoritative for resources managed by each root. Sol run
logs are diagnostic only. Sol records no authoritative phase pointer; every run
derives what remains from Terraform state and live observations.

### Cross-root interface

After the cloud phase succeeds, Sol reads `terraform output -json` from the
cloud root, validates an explicit AWS output contract, and passes the required
values as explicit variables to the platform root. `infra/base` does not read
the AWS state backend and no `terraform_remote_state` dependency is introduced.

The contract is typed and named for actual requirements (for example
`cert_manager_irsa_role_arn`, durable-observability bucket/role bindings and
managed-resource dashboards). There is no generic arbitrary-output-to-tfvar
mapping layer. Sensitive outputs remain subject to their existing handling
rules and are not printed or written to Sol logs.

### Forward reconciliation

For AWS, `sol cloud apply` performs and logs these idempotent phases:

1. initialize the cloud root against its durable state;
2. apply and verify the AWS cloud substrate;
3. read and validate the cloud output contract;
4. configure access to the cluster;
5. initialize the platform root against its separate durable state;
6. apply cert-manager and its namespace;
7. verify the required cert-manager CRDs are `Established`;
8. apply the remaining platform substrate with the explicit cloud bindings;
9. verify target readiness from the live cluster; and
10. remove bootstrap access and verify the separate bounded steady-state
    cluster-access identity's effective RBAC and IAM boundary.

Steps 6–9 run under the temporary privileged `PlatformInstalling` authority
(ADR 0003); it is revoked at step 10.

Re-running the command after any interruption is the resume mechanism. An
already-satisfied phase is harmless; an incomplete phase is reconciled again.

Readiness is observed, never inferred from target variables, Terraform state or
generic "pods look healthy" output. It uses the existing preflight result
vocabulary (`Established` or `Unmet` with side and reason) and fails closed.
Every installed required component owns a named live predicate appropriate to
that component. For the AWS-qualified platform these include:

- cert-manager: required CRDs report `Established`, controller/webhook/cainjector
  workloads are available, and the selected `ClusterIssuer` reports `Ready=True`;
- storage: the EBS CSI addon is active and the selected `StorageClass` exists,
  uses the expected CSI provisioner and carries the default-class annotation;
- Redpanda: every expected broker is ready and the broker-native cluster-health
  check reports healthy (not merely that its StatefulSet pods are Running);
- ingress and Argo CD: their required controllers are available, and cloud
  ingress has an assigned address when a `LoadBalancer` is requested;
- observability: each installed service passes its native readiness endpoint,
  while collectors/agents meet their controller-specific desired-versus-ready
  condition; and
- optional in-cluster PostgreSQL: the StatefulSet is ready and `pg_isready`
  succeeds.

The implementation keeps this as an explicit component-to-predicate contract so
adding a required component cannot silently inherit a generic pod-health test.

Application workspace substrate remains outside this command. Namespaces and
workspace runtime material are established idempotently by application lifecycle
commands (`sol deploy` / `sol migrate`); one target may serve many workspaces.

### Provisioning and cluster-access identities

Cloud provisioning and steady-state cluster access are separate authority
domains (DEC-034). The named cloud-provisioning identity owns the AWS substrate
and the bootstrap EKS access association. A distinct cluster-access identity
owns the EKS access entry and group binding used by scoped platform paths.
Apply temporarily associates AWS's managed cluster-admin access policy with the
cluster-access principal for the whole privileged
`PlatformInstalling` phase — the full platform apply **and** verified readiness
— then removes the association and verifies the effective steady-state
permissions. Installing cluster-wide software that mints RBAC is privileged
platform establishment, so the window is not closed at the first custom-RBAC
object (ADR 0003 defines the phase contract). Sol creates an isolated ephemeral
kubeconfig for each platform phase; it never uses cluster-creator admin, the
namespace-scoped deployer, or an ambient kubeconfig/current context.

The cloud provisioner remains a highly privileged infrastructure identity: authority
over CRDs, controllers and admission-related cluster resources can indirectly
affect workloads. The enforceable negative boundary is narrower. Its direct
Kubernetes permissions are not used in steady state. The cluster-access
identity's direct Kubernetes permissions are limited to resources and verbs required by the
supported platform lifecycle in platform namespaces and exclude ordinary
application Deployments, Services, Jobs and Secrets outside those namespaces.
Its IAM policy allows EKS discovery/credential retrieval but denies access-entry,
policy-association, and all IAM mutation, so it cannot recreate the temporary
installation grant. No claim is made that either identity is equivalent to a
low-privilege workload identity.

The security domains are:

| Identity | May | Must not |
| --- | --- | --- |
| cloud provisioner | reconcile cloud substrate and bootstrap access | act as steady-state Kubernetes access or publish images |
| cluster access | reconcile scoped platform substrate through Kubernetes RBAC | mutate EKS access entries/policy associations, mutate IAM, or directly mutate ordinary application resources outside platform namespaces |
| publisher | publish/replace application images | provision substrate or deploy workloads |
| deployer | deploy immutable application artifacts | provision substrate or publish/replace images |
| operator | perform explicitly declared operational actions | provision, publish or deploy beyond those actions |

This ADR establishes only the provisioner access needed by this lifecycle and
its negative boundaries. Finding 6 owns comprehensive effective-permission
qualification across all four identities.

### Inverse reconciliation

Destroy is an explicit lifecycle:

```text
Ready -> prepare destruction -> verify preparation -> destroy platform
      -> destroy cloud -> verify absence
```

Finding 5 establishes this phase boundary even where preparation is currently a
no-op. Finding 9b supplies AWS RDS semantics later: disable deletion protection
through an applied transition and establish a unique final-snapshot identity.
A failed destroy after preparation remains observable and safely re-runnable.
Once preparation is verified the Destroy policy governs (ADR 0003): no later
reconciliation in this lifecycle re-applies the Ready/Production invariant, so
deletion protection is not silently restored between preparation and
destruction. `sol cloud apply` reconciles back toward protected Ready state when
the target is (or returns to) Ready — for example when a prior destroy attempt is
abandoned — which is why destroy must first leave the Ready policy domain.

### Provider and local scope

This implementation and qualification are AWS-only. An unsupported provider
must report the lifecycle capability as unmet; GCP adopts the same semantic
phase interface only after its own live qualification.

Local development shares lifecycle semantics and application contracts, not the
AWS/Terraform mechanism. `sol local` is not routed through these Terraform roots
for symmetry.

### Qualification boundary

`internal/qualification/aws/live-smoke.sh` may invoke public Sol commands, independently read
AWS/Kubernetes state, and inject qualification failures. It must not invoke
Terraform or Helm to provision, repair or finish a Sol lifecycle phase. This is
enforced mechanically so the qualification harness cannot regain a shadow
implementation.

## Consequences

- `sol cloud apply` becomes the single public operation from declared AWS target
  to verified ready target; the tutorial no longer asks operators to finish it.
- The roots stay independent and keep distinct blast radii while Sol owns their
  semantic dependency.
- Normal reconciliation is portable across clean runners after bootstrap.
- Partial failure needs no new state machine or phase database.
- Direct Terraform remains an advanced escape hatch, but using it no longer
  defines the supported lifecycle or qualification path.

## Alternatives rejected

- **`terraform_remote_state` in `infra/base`:** couples the platform substrate
  to the AWS root's storage mechanism instead of its semantic outputs.
- **Merge both roots:** expands blast radius and combines genuinely different
  provider/credential lifecycles.
- **Operator-authored backend files:** makes recovery machine-dependent and
  contradicts Sol's resumability claim.
- **A Sol phase-pointer file:** duplicates reality and can lie after partial
  failure; Terraform state plus live verification already provide the evidence.
- **Mutate during plan to unlock later plans:** violates plan semantics; an
  explicit successful `Deferred` result describes the staged lifecycle honestly.
- **A separate platform-installer or a broader deployer:** splits one provisioning
  lifecycle by mechanism or expands application authority unnecessarily. The
  provisioner already owns substrate establishment.
- **Qualify GCP/local in the same remediation:** widens an observed AWS defect
  without evidence that identical machinery is appropriate.

## Related

- ADR 0003 — lifecycle phases determine authority and desired-state policy
- HARDEN-002, findings 5, 7 and 9
- DEC-026 — `production-single-region/v1`, initially qualified on AWS EKS
- DEC-027 — disciplined imperative reconciliation authority
- AUDIT-072 — durable state facility and scoped identities
- INFRA-022 — implementation ticket
