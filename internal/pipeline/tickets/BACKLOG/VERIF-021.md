---
id: VERIF-021
type: verification
severity: medium
title: Qualify AWS and GCP managed secret projection live — ASCP rotation, IAM denial, and the GKE add-on rotation interval
source: DEC-029 (2026-10-02 resolution) — the gated live runs in the saved P1–P8 plan
---

**Depends on:** None.

## Blocked On

The operator's explicit authorization for a live-qualification run (AGENTS.md
§ Live qualification), and a qualified target to run against. This is a live-cloud
run and is not started without that authorization.

## Scope

Two live cells from DEC-029's driver × runtime table, run under the qualification
ledger's rules (strict evidence, no in-run remediation):

1. **AWS (`aws` × Kubernetes).** Install Secrets Store CSI driver + AWS provider
   on a qualified EKS cluster; confirm the provider authenticates as the *pod's*
   identity (IRSA / EKS Pod Identity), never the node's; confirm a workload whose
   IAM grant is removed is denied (`AccessDenied`) while a granted one reads;
   confirm `enableSecretRotation` updates the mounted file within the stated
   bound and that a new pod fails closed while the authority is unavailable.
2. **GCP (`gcp` × Kubernetes).** On the pinned GKE Standard version, enable the
   Secret Manager add-on and confirm rotation is GA and works at the configured
   `--secret-manager-rotation-interval` (default 2m, minimum 2m); confirm a
   forbidden KSA/WIF principal is denied and the mounted file refreshes.

Also qualify the AWS claim from `DEC-062` rule 6: whether
`iam:SimulatePrincipalPolicy` reflects permissions boundaries, resource policies
and SCPs. Where it does not, the deploy-time verification needs a mechanism that
does.

## Acceptance criteria

- Each cell records the exact commands and observed outputs, the provider version
  and CSI driver version, and the measured rotation→file-change delay.
- The DEC-029 comparison rows for AWS/GCP move from `to qualify` to the observed
  verdicts, or state precisely which property failed.
- The components added are recorded for the `FEAT-088` compatibility matrix and a
  `DEC-026` §9 re-qualification is scheduled.
- `SimulatePrincipalPolicy` is confirmed or falsified as a boundary-aware check;
  the answer is recorded on `DEC-062`.
- Language parity: no application-facing contract change; state that in one line.
- Demo/example: not applicable — a qualification run, not an app-author-visible
  change.
