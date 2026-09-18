---
id: INFRA-028
type: bug
severity: high
title: Lifecycle phases determine authority and desired-state policy
branch: INFRA-028/lifecycle-phases
source: HARDEN-002 run 4, 2026-09-18 — findings 13, 14 and 15, plus the
  straightforward findings 10-12 already fixed on the same working tree
---

**Depends on:** None.

**Related:** ADR 0002 (superseded in part), ADR 0003 (new), BUG-039 (RDS
deletion protection invariant — unchanged), INFRA-022 (provisioner boundary
invariant 11), INFRA-023 (destroy preparation), INFRA-025 (deploy RBAC),
HARDEN-002 (`production-single-region/v1` qualification).

## What this is

HARDEN-002 runs 3 and 4 exercised the public lifecycle against fresh AWS targets
and surfaced six defects. Three were ordinary transition/wiring bugs:

- **Finding 10** — `aws_outputs_of_json` crashed when an optional Terraform
  output was absent (Terraform omits null-valued outputs); blocked both apply and
  destroy.
- **Finding 11** — `target.deploy_role_arn` was never routed to the provider
  root, so the deploy EKS access entry was never created.
- **Finding 12** — the platform Terraform received only `KUBECONFIG`, but
  `hashicorp/kubernetes` 2.38.0 resolves the kubeconfig from
  `KUBE_CONFIG_PATH`/`KUBE_CONFIG_PATHS`, so the platform phase silently used the
  ambient `~/.kube/config`.

The other three shared one root cause the design did not model — *which
operation Sol is performing* decides both the authority it may use and which
desired-state policy applies:

- **Finding 13** — the steady-state provisioner could not create the deploy
  identity's `sol-deploy` ClusterRole: Kubernetes' RBAC privilege-escalation
  check forbids granting permissions the creator does not hold.
- **Finding 14** — the same check rejected third-party chart RBAC (the
  prometheus chart's `prometheus-server` ClusterRole) during the full platform
  apply, which ran *after* the temporary cluster-admin association had been
  removed.
- **Finding 15** — `sol cloud destroy` prepared destruction (deletion protection
  off, unique final snapshot, verified) and then re-applied ordinary production
  desired state before destroying, restoring `rds_deletion_protection=true` and
  stranding the instance. Public destroy then could not complete; disposal
  needed the operator escape hatch.

Two individually-correct rules contradicted each other only because nothing said
which was in force: `BUG-039` requires production RDS deletion protection true
throughout `Ready`; `INFRA-023` requires it false in `PreparingDestroy`.

## Decision

ADR 0003 (`docs/architecture/adr/0003-lifecycle-phases-authority-and-policy.md`)
makes the lifecycle phase an explicit concept that determines authority and
desired-state policy:

```
Absent -> CloudBootstrap -> PlatformInstalling -> (verify) -> Ready
                                          ^                     |
                                          +-- PlatformUpdating -+
Ready -> PreparingDestroy -> Destroying -> Absent
```

| Phase | Authority | Desired-state policy |
| --- | --- | --- |
| `CloudBootstrap` | temporary privileged | Bootstrap |
| `PlatformInstalling` | explicitly privileged installation authority | Installation |
| `Ready` | bounded provisioner | Production |
| `PlatformUpdating` | temporarily privileged installation authority | Installation |
| `PreparingDestroy` | explicit destroy authority | Destroy |
| `Destroying` | destroy authority | Destroy |

Invariants: the privileged installation authority spans the whole platform
install (full apply **and** verified readiness) and is revoked only at the
verified Ready transition; the steady-state provisioner never holds
`escalate`/`bind` and cannot manufacture a more powerful identity; a privileged
platform change is an explicit `PlatformUpdating` re-entry; and once
`PreparingDestroy` is verified, Ready policy must not run again. The phase record
is the operation/transition Sol is performing, **not** infrastructure truth —
Terraform state stays authoritative for managed resources and AWS/Kubernetes
provide observed reality, so no phase pointer or second state database is added.

## Remediation

- `cli/sol/lib/sol_cli_cloud_lifecycle.ml/.mli` — add `phase`, `phase_policy`,
  `policy_of_phase`, `transition_allowed`, `ready_policy_applies` and
  `policy_vars`.
- `cli/sol/bin/cmd_cloud_tf.ml` — Finding 14: keep the temporary privileged
  authority open through the full platform apply and verified readiness, then
  de-escalate and verify the bounded provisioner; revert Finding 13's interim
  staging of the deploy RBAC in `platform_prerequisite_targets` (the full apply
  now runs inside the privileged phase). Finding 15: the post-prepare
  bootstrap-admin apply and the destroy run under the Destroy policy, with its
  overrides appended after the profile's `rds_deletion_protection=true`, and
  preparation is re-verified after that apply.
- Findings 10-12 remain fixed: the absent-output parser, the `deploy_role_arn`
  routing and the kubeconfig environment (`provisioner_kube_env`).
- Docs: ADR 0003 (new); ADR 0002 updated ("temporary cluster-admin only to create
  the custom RBAC" and "apply always reconciles back toward protected Ready
  state" superseded); `docs/deployment/production-bootstrap.md` §3 and
  `docs/guides/TUTORIAL.md` updated; INFRA-022 invariant 11 carries a refinement
  note.

## Acceptance criteria

- A fresh `sol cloud apply` on a production-profile target installs the platform
  (including chart RBAC and the deploy RBAC) inside the privileged phase and only
  then de-escalates; the steady-state provisioner retains no `escalate`/`bind`.
- `sol cloud destroy` on a protected RDS instance prepares, verifies, destroys
  and verifies absence without any intervening reconciliation restoring deletion
  protection.
- Tests assert the semantics, not only the original bugs: the transition
  relation (including rejected `PreparingDestroy -> Ready`), the policy override,
  install-before-de-escalation, and the Destroy-policy ordering after
  `PrepareDestroy`.
- BUG-039 is unchanged: production RDS deletion protection remains an enforced
  invariant throughout `Ready`.

## Evidence (local)

- `dune build` green; full `dune build @runtest` green.
- Offline lifecycle harness, public-cloud-lifecycle, publisher/deployer-boundary
  and production-infra guards pass.
- Pre/post proofs: reverting the ordering fails with "the platform install must
  complete before provisioner de-escalation"; reverting the destroy vars fails
  with "the post-prepare bootstrap-admin apply did not carry the Destroy policy".
- Live: run 4 confirmed findings 10-13 fixed on a real target and reproduced 14
  and 15; run 5 will re-qualify under the explicit model.
