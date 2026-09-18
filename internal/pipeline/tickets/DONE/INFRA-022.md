---
id: INFRA-022
type: feature
severity: high
title: Make sol cloud own the complete AWS target lifecycle
source: HARDEN-002 run 2 finding 5; ADR 0002
---

**Depends on:** AUDIT-072, DEC-026, DEC-027.

**Related:** HARDEN-002 findings 5, 7 and 9; ADR 0002; finding 9b follow-up.

`sol cloud apply <target>` currently applies only `cli/platform/infra/aws`.
The working base-platform staging, cloud-to-platform wiring and platform teardown
live outside the public command in `devtools/aws-live-smoke.sh`. Implement ADR
0002 so one AWS lifecycle command reconciles a declared target to verified Ready
and can resume from durable state on a clean runner.

## Resolved design

- `sol cloud plan` is non-mutating and reports each phase as planned or
  `Deferred` with its concrete unavailable prerequisite. Deferred is distinct
  from readiness/preflight `Unmet`. The command exits zero when every currently
  plannable phase succeeds, even when later phases are Deferred; it exits
  non-zero for a plannable-phase failure or invalid/unavailable config, state or
  authentication.
- The existing named provisioner owns both AWS infrastructure and cluster-wide
  platform installation. The cloud phase establishes an explicit EKS access
  entry/policy binding for that principal; the platform phase obtains isolated
  cluster access as it. It never uses cluster-creator admin, ambient kubeconfig,
  the current context or the namespace-scoped deployer.
- Keep four negative security boundaries: the constrained high-privilege
  provisioner cannot publish images and its direct Kubernetes grants exclude
  ordinary application mutation outside platform namespaces; publisher cannot
  provision/deploy; deployer cannot provision or replace artifacts; operator
  has only explicitly declared operational powers. CRD/controller authority can
  still indirectly affect workloads. This ticket establishes the provisioner
  boundary needed here; finding 6 owns comprehensive effective-permission
  qualification.

## Scope

- Initialize AWS and base roots with runtime backend configuration derived from
  the target's conformant state declaration. Use separate deterministic state
  keys; create no tracked or operator-authored `backend.tf`.
- Apply and verify the AWS root, read `terraform output -json`, validate the
  required named output fields, and pass only those explicit inputs to the base
  root. Do not add `terraform_remote_state` or generic mapping configuration.
- Have the AWS root establish and output the named provisioner's EKS
  platform-management binding. Build platform-phase cluster access explicitly
  for that principal; do not consume ambient kubectl state.
- Move the cert-manager/CRD staging from the smoke harness into the public
  lifecycle: apply cert-manager, wait for required CRDs to become Established,
  then apply CRD-dependent and remaining platform resources.
- Verify Ready from live cluster state through an explicit predicate for each
  installed required component, as specified by ADR 0002: cert-manager CRDs and
  controllers plus `ClusterIssuer`; EBS CSI plus the default `StorageClass`;
  Redpanda broker-native cluster health; ingress and Argo CD controllers;
  native observability readiness plus collector controller status; and
  `pg_isready` when in-cluster PostgreSQL is installed. Reuse the preflight
  `Established | Unmet (side, reason)` vocabulary and fail closed; do not use a
  generic pod-health predicate.
- Extend `sol target show <target> --check` to show that readiness result.
- Make apply resumable without a Sol-owned phase marker. Every phase must be
  safe to re-run after the process stops at any preceding boundary.
- Give `sol cloud destroy` the declared prepare/verify/destroy/verify skeleton.
  Preparation may be a no-op except where semantics already exist; the RDS
  deletion-protection/final-snapshot behavior remains finding 9b's implementation.
- Update the tutorial and production-bootstrap documentation so the public Sol
  command is the normal path and direct Terraform is only an explicit escape
  hatch.
- Reduce `devtools/aws-live-smoke.sh` to Sol orchestration, independent read-only
  AWS/Kubernetes assertions and fault injection.

## Acceptance invariants

1. **One public operation:** on a fresh bootstrapped AWS target,
   `sol cloud apply <target>` reaches verified Ready without direct Terraform,
   Helm or out-of-band Kubernetes mutation.
2. **Durable clean-runner resume:** interrupt after each mutating phase in turn;
   rerun from a runner with no prior `.terraform` directory or local tfstate;
   reconciliation resumes from the two durable state objects and reaches Ready.
3. **Separate state:** cloud and platform roots use distinct backend object keys.
   Destroying/reinitializing one root cannot make Terraform claim ownership of
   the other's resources.
4. **Explicit wiring:** the base apply receives its required AWS bindings from
   validated AWS output fields. A missing or wrong-typed required output fails
   before platform mutation and names the field; no base configuration reads AWS
   remote state.
5. **Real CRD boundary:** qualification proves cert-manager/CRDs are applied and
   observed Established before any `ClusterIssuer` plan/apply. A Terraform
   `depends_on` assertion alone cannot satisfy this invariant.
6. **Observed readiness:** Ready is withheld when any required CRD,
   `ClusterIssuer`, default `StorageClass`, or installed required component fails
   its ADR 0002 live predicate, even if Terraform state/configuration says it
   should exist. Every required component maps to a named predicate; none falls
   through to a generic pods-Running check.
7. **Protection recovery:** a failed destroy after preparation is visible and
   re-runnable; a subsequent `sol cloud apply` reconciles the target toward the
   protected Ready state. The lifecycle hook exists here; RDS-specific mutation
   lands with finding 9b.
8. **No shadow provisioner:** `devtools/aws-live-smoke.sh` contains no Terraform
   or Helm invocation. CI enforces this structurally while permitting independent
   AWS/Kubernetes reads and explicit fault injection.
9. **AWS-only, fail closed:** the qualified behavior is implemented for AWS.
   GCP reports the lifecycle capability unmet rather than silently running the
   old incomplete path. `sol local` is unchanged except for any shared semantic
   vocabulary that requires no Terraform coupling.
10. **Honest plan:** on both absent and partially reconciled targets, `sol cloud
    plan` exits zero after all currently plannable phases succeed, labels later
    phases `Deferred` with their concrete lifecycle prerequisite, and never
    labels one previewed. It mutates nothing. A plannable-phase failure or
    invalid/unavailable target, state or authentication exits non-zero.
11. **Provisioner boundary:** the platform phase authenticates as the declared
    provisioner through the cloud-established EKS binding. Qualification proves
    it can perform the required cluster-wide platform mutations and denies
    representative direct ordinary application mutations outside platform
    namespaces. It is not granted standing cluster-admin, and neither
    cluster-creator admin nor deployer credentials can satisfy the test.

## Smallest useful checks

- One orchestration test records phase calls and injects failure after each
  boundary, then reruns and asserts the complete ordered lifecycle without a
  phase-pointer file.
- One output-contract test covers valid, missing and wrong-typed AWS outputs.
- One readiness test covers each named unmet observation and the all-Established
  case.
- One plan test covers absent, prerequisites-only and fully-established targets,
  including zero exit with Deferred phases, non-zero on a plannable failure and
  no mutation in every case.
- One identity test proves the generated platform access selects the named
  provisioner and rejects ambient, cluster-creator and deployer credentials.
- One shell guard rejects `terraform` or `helm` execution in
  `devtools/aws-live-smoke.sh`.
- HARDEN-002 run 3 supplies the live fresh-target and clean-runner evidence; unit
  or HCL-shape tests do not substitute for it.

## Not in scope

- GCP implementation or qualification.
- Routing `sol local` through Terraform.
- Generic lifecycle plugins, arbitrary output mappings or a Sol phase database.
- Changing workspace-substrate ownership from `sol deploy` / `sol migrate`.
- Implementing finding 9b's RDS preparation semantics in this ticket.

**Demo/example coverage:** use the existing Pluto AWS production-profile target;
do not add a lifecycle-only fixture.

**TypeScript parity:** not applicable to target provisioning; language
qualification remains DEC-026/FEAT-088's boundary.

## Completion notes

- **Premise verified** 2026-09-17: at branch start `sol cloud apply` still
  applied only `cli/platform/infra/aws`, the base/cert-manager staging lived
  only in `devtools/aws-live-smoke.sh`, and the platform inputs crossed by hand.
  All three still held, so the work was outstanding.
- **Demo/example coverage:** the existing Pluto target files gained the new
  required `letsencrypt_email` platform input; no lifecycle-only fixture was
  added, per this ticket. Live qualification targets stay untracked by design
  (`devtools/ci/check_no_account_artifacts.sh`).
- **TypeScript parity:** not applicable (see above).
- **Offline evidence:** `devtools/ci/test_cloud_lifecycle_offline.sh` runs the
  ordered apply with fault injection after every mutating boundary and a resume
  from the two durable state keys; the plan matrix (absent / provisioner-RBAC
  absent / prerequisites-only / fully established / plannable failure) with no
  mutation; and GCP fail-closed. Unit coverage: output contract, readiness
  predicates, plan phases, effective authorization. Live fresh-target and
  clean-runner evidence remains HARDEN-002 run 3's per this ticket.
