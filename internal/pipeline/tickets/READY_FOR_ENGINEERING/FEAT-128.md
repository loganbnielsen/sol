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
