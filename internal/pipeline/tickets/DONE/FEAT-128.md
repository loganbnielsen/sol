---
id: FEAT-128
type: feature
severity: high
title: Deploy verifies effective cloud access read-only, and never repairs it
source: DEC-062 (2026-10-02 resolution) — implementation split, rule 6
---

**Depends on:** FEAT-127.

**Related:** `DEC-062` (rule 6, and rule 3's plan-time refusal), `DEC-052`
(observed, not asserted), `VERIF-021` (the `SimulatePrincipalPolicy`
qualification this mechanism depends on), `VERIF-020` (the capability
comparison that says which capabilities need grants at all).

## Premise

`sol deploy` today verifies the Kubernetes substrate and the workload Secret, and
the deploy identity's policy carries no IAM-mutating action
(`check_deploy_identity_iam.py`). It does **not** observe whether a unit's
declared cloud grants are effective: `rg -q 'SimulatePrincipalPolicy' cli/lib`
is false.

## What this is

`sol deploy` proves that each unit has the effective cloud access its
declarations require, by observing the provider, read-only.

## Required behaviour

- **Observe, never assert.** Verification reads the provider (AWS
  `iam:SimulatePrincipalPolicy` against the unit's role for each required action
  and resource; GCP reads the granted resource's IAM policy for the unit's
  principal). It never trusts a Sol-generated record that grants were applied
  (`DEC-052`).
- **Read-only, and it never repairs.** The deploy identity gets read-only IAM
  visibility and nothing that mutates IAM. A missing or ineffective grant is
  **reported and refused**, never created, widened or repaired by the deploy
  path; the message names the unit, the missing grant and the reconciliation to
  run (rule 3).
- **Fail before applying.** The refusal happens at plan time, so no pod is left
  hanging in `ContainerCreating` waiting for a grant that does not exist.
- **Effective, not declared.** The verification must reflect real evaluation —
  permissions boundaries, resource policies and SCPs included. Where
  `SimulatePrincipalPolicy` does not (VERIF-021), the verification uses a
  mechanism that does, and this ticket records which was used.

## Acceptance criteria

- A unit whose declared grant is not effective fails `sol deploy` at plan time,
  with a message naming the unit, the grant and the reconciliation to run; a test
  asserts the refusal and that nothing was applied.
- The deploy identity's policy gains only read-only IAM visibility; the existing
  `check_deploy_identity_iam.py` guard still passes and is extended to cover any
  new read-only action.
- No code path in deploy creates, attaches, updates or deletes a role, policy or
  binding; a test asserts the read-only path (or a structural guard does).
- A grant that is declared and effective passes verification.
- The chosen mechanism and its qualification state are recorded (rule 6 names
  `VERIF-021` for the AWS simulation).
- Demo/example: the pluto deploy fails with the stated message when a required
  grant is withheld, or the ticket records in one line why not. No
  language-parity impact (`DEC-022`): platform authorization only.

## Completion (2026-10-02)

**Premise verified.** Before this change `rg -q 'SimulatePrincipalPolicy' cli/lib` was
false and no deploy path observed effective access. It is now the AWS mechanism.

**Landed.**

- `sol deploy` verifies each unit's declared grants before it applies anything: the
  check runs in `cmd_deploy.run_apply` after the plan and substrate/migration
  preconditions and before `Sol_cli_deploy_run.apply`, so a missing grant fails at plan
  time and no pod waits in `ContainerCreating` (`DEC-062` rule 3).
- **AWS mechanism:** `iam:SimulatePrincipalPolicy` against the unit's role
  (`arn:aws:iam::<account>:role/sol/<env>/sol-<env>-<unit>`) for
  `secretsmanager:GetSecretValue` on `sol/<env>/<key>`; the account id comes from
  `sts:GetCallerIdentity`. Its fidelity — permissions boundaries, resource policies and
  SCPs — is the `VERIF-021` qualification, still gated; until it runs, the mechanism is
  recorded as **implemented, qualification pending** rather than qualified.
- **GCP mechanism:** `gcloud secrets get-iam-policy` read for the unit's Workload
  Identity principal.
- The deploy identity's policy gains only read-only IAM visibility
  (`iam:SimulatePrincipalPolicy` plus `Get`/`List`). Because an explicit Deny of `iam:*`
  would override it, the Deny now enumerates the IAM-mutation families, and
  `check_deploy_identity_iam.py` requires every one of them; its mutation suite gained
  "a denied family narrowed to a read-only action" and "the observation Allow widened to
  a mutation".
- **Unit identity correction.** The reconciler and the verification now name a unit by
  its Kubernetes ServiceAccount (the sanitized `k8s_name`), not the raw source directory
  name. FEAT-127 used the source name, which diverged for a unit such as `charge_svc` →
  `charge-svc`; `Sol_cli_authorization_reconcile.unit_name` is the single derivation both
  `sol grants` and `sol deploy` use, so desired, applied and observed grant sets agree.

**Tests.** `cli/test/inline/test_authorization_verify.ml` covers an effective AWS grant
passing, an ineffective one refused with the unit, the grant and the reconciliation to
run, a unit with no declared grant triggering no cloud call, an unobservable check
failing closed, the GCP positive and negative cases, the ServiceAccount-name identity,
the per-unit grouping, and that the observation path never issues a mutating IAM call.
`check_deploy_identity_iam.py` and its mutation suite pass, the bootstrap root
`terraform validate`/`terraform fmt -check` clean, and the full fast-check set passes.

**Demo/example.** `examples/pluto/README.md` shows the stated deploy-time refusal and the
read-only deploy identity. No language-parity impact (`DEC-022`): platform authorization
only.

**Open.** `VERIF-021` is the AWS simulation's live qualification; a mechanism that does
not reflect real evaluation would replace it (rule 6). The `secret` capability family is
the one realized; IAM database auth, MSK IAM auth and object storage extend the same
check.

