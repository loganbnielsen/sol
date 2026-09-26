---
id: INFRA-046
type: refactor
severity: high
title: Split the cloud-provisioning identity from the steady-state cluster-access identity
source: DEC-034 / audit finding FND-0002 — the AWS provisioner can re-grant itself cluster-admin via eks:AssociateAccessPolicy
---

**Depends on:** none (the decision is made).

**Related:** DEC-034 (the decision), FND-0002
(`internal/pipeline/audits/findings/FND-0002-aws-provisioner-cloud-api-escalation.md`),
ADR 0002 (to be revised), ADR 0003 (invariant 2),
`cli/platform/infra/bootstrap/main.tf` (provisioner policy),
`cli/platform/infra/aws/main.tf` (the access entry),
`cli/sol/bin/cmd_cloud_tf.ml` (`require_credentials`,
`provisioner_kubeconfig`), `internal/qualification/aws/production-single-region-v1-matrix.md`
(row I3), INFRA-045 (the GCP counterpart).

## The finding

The provisioner IAM policy grants `eks:*`
(`cli/platform/infra/bootstrap/main.tf:81`), which includes
`eks:AssociateAccessPolicy` / `eks:CreateAccessEntry` / `eks:UpdateAccessEntry`.
The provisioner already owns an access entry, so it can associate
`AmazonEKSClusterAdminPolicy` with that entry and obtain cluster-admin at will.
The deploy policy already refuses this with an explicit
`NoInfrastructureOrIdentityMutation` deny; the provisioner does not.

## What to do (DEC-034)

1. Keep a **cloud-provisioning identity** that owns the cloud substrate and the
   bootstrap access entry/association (`eks:*` as today, or the minimal set the
   cloud root genuinely uses).
2. Introduce or re-scope a **steady-state cluster-access identity** assumed by
   the scoped platform paths. Its policy must grant **no**
   `eks:AssociateAccessPolicy`, `eks:CreateAccessEntry`,
   `eks:UpdateAccessEntry` and **no** `iam:*`.
3. Make the lifecycle use the steady-state identity where it currently uses the
   single provisioner role, and record which identity each mutating stage used.
4. Revise ADR 0002, `production-bootstrap.md` and matrix row I3 to the split
   model, and remove the "cannot manufacture a more powerful identity" claim
   about the single provisioner.

## Acceptance criteria

- The steady-state identity's policy grants no access-entry / policy-association
  permission and no `iam:*`. An offline guard pins this (same shape as
  `internal/ci/check_runtime_secret_identity.sh`) so the over-grant cannot return
  unnoticed.
- ADR 0002 and matrix row I3 describe the two identities; no document retains the
  single-provisioner escalation claim.
- A live probe records the escalation as **denied** for the steady-state identity
  — either the post-closure `can-i` path plus an `aws eks associate-access-policy`
  attempt under that identity, or an equivalent recorded observation. The claim
  must be falsifiable (HARDEN-003): feed the violated condition and confirm the
  check rejects it.
- GCP is reconciled with INFRA-045 so the split is provider-neutral, not an
  AWS-only shape.

## Out of scope

The Kubernetes RBAC boundary itself — it is real and already probed
(`provisioner_authorization_checks`). This ticket is about the IAM identity, not
the in-cluster roles.

**Demo/example coverage:** Not applicable.

**TypeScript parity:** No language-parity impact.

## Implementation record (2026-09-19)

Implemented on `codex/infra-046` without a provider run:

- `provisioner_role_arn` remains the cloud-provisioning declaration;
  `cluster_access_role_arn` is now a distinct required AWS lifecycle field and
  owns the EKS access entry used by scoped platform paths.
- the bootstrap root emits a discovery-only cluster-access IAM policy with
  explicit access-entry, policy-association, and `iam:*` denies;
- `internal/ci/test_cluster_access_identity.sh` pins the split and proves the
  guard rejects both a removed deny and a newly allowed mutation;
- ADR 0002/0003, the production bootstrap guide, tutorial, and matrix I3 now
  state the two-identity model.

Static/unit acceptance is complete. The required recorded denial under the
real steady-state identity remains qualification evidence for the next AWS live
run; this implementation performed no live/provider operation.

## Landed (2026-09-20)

Merged in #376 (DEC-034, FND-0002). The bounded `cluster_access` policy contract allows
cluster discovery and explicitly denies access-entry/policy-association mutation and all
`iam:*`; the EKS access entry (carrying the temporary bootstrap-admin association) now
belongs to that identity, so the install window still applies to the identity whose
kubeconfig is used; `cluster_access_role_arn` is AWS-only. `check_cluster_access_identity.sh`
and its mutation test pass. ADR 0002, ADR 0003, `production-bootstrap.md` and matrix row I3
no longer carry the single-provisioner escalation claim.

**Outstanding (behavioural, FND-0002 stays `FIXED_UNQUALIFIED`):** a run must record that
the steady-state identity's `aws eks associate-access-policy` attempt is denied (plan item 9).
