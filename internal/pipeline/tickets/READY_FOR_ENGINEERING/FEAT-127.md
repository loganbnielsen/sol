---
id: FEAT-127
type: feature
severity: high
title: Implement the authorization reconciler entry point and wire the authorization root
source: DEC-062 (2026-10-02 resolution) — implementation split
---

**Depends on:** None.

**Related:** `DEC-062` (the contract and the six rules), `DEC-029` (the `secrets`
capability this first serves), `DEC-061` (declaration decides where, execution
identity decides whether), `FEAT-109` (the CI authorization job that assumes the
reconciler), `VERIF-021` (the fence's live qualification).

## Premise

The `authorization` Terraform root and its fence already exist
(`platform/cloud/{aws,gcp}/authorization/`, DEC-062 parts C/D), and
`Sol_cli_authorization` computes the safe grant set (part B). Nothing stages,
plans or applies the root yet: `rg -q 'Authorization' cli/lib/cloud/sol_cli_environment_stage.ml`
is false, and no CLI command reaches `Sol_cli_authorization.compute`.

## What this is

The reconciler's entry point: staging, planning and applying
`platform/cloud/<provider>/authorization` for a target, under the reconciler's
own identity, with the safe grant set as its generated input.

## Required behaviour

- **Fence created by the provisioner.** `sol cloud apply` creates the reconciler
  identity and its fence (DEC-062 rule 2); the reconciler can neither create nor
  alter its own fence.
- **Separate privilege.** The plan/apply path is assumed as the reconciler
  (`reconciler_role_arn` / the GCP reconciler service account), never as
  `deploy_role_arn`. Running it as the deploy identity must fail closed.
- **Target-wide, no scope.** The operation reconciles the whole workspace
  authorization graph for the target and has **no** unit or domain scope — an
  invariant of the API, not just of a flag (rule 5), so no future caller can
  reintroduce partial reconciliation.
- **Safe grant set is the input.** Only `Sol_cli_authorization.compute`'s `keep`
  set becomes the root's generated input, so Terraform cannot revoke a grant rule
  4 says to hold (rule 4). Additions are computed independently of pending
  removals.
- **Readable plan.** The plan renders `+ unit → capability/resource` and
  `- unit → capability/resource`, so a reviewer sees a production credential being
  granted (rule 1).
- **Deployed requirements are observable.** Each deployed workload records the
  grants it was deployed against (an annotation the reconciler reads with
  read-only Kubernetes access); without it, rule 4's observation does not exist.
  The carrier is an implementation choice, the observation is not.

## Acceptance criteria

- A CLI entry point plans and applies the authorization root for an explicit
  target; the target is the positional (DEC-031), and there is no scope flag.
- The reconciler path assumes the reconciler identity; a test shows it is refused
  when only the deploy identity is available.
- The generated Terraform input is the safe `keep` set; a test covers a removal
  held because a deployed workload still uses it, and one held because the
  deployed state is unobservable (rule 4).
- No scope parameter exists anywhere in the reconciler's types (rule 5), with a
  test that reconciles every declared domain in one operation.
- The plan output is asserted to name the unit, the capability and the resource
  (rule 1).
- Deployed requirements are recorded and read back, with a test.
- `check_provider_roots.sh` and `check_destroy_completeness` still pass with the
  root staged; teardown destroys the root's resources.
- Demo/example: `examples/pluto` shows a grants plan followed by a deploy, or the
  ticket records in one line why not. No language-parity impact (`DEC-022`):
  platform authorization only.

## Out of scope

Deploy-time read-only effective-access verification (rule 6) is `FEAT-128`. The
fence's live behaviour is `VERIF-021`.
