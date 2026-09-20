# FND-0002 — AWS provisioner can re-grant itself cluster-admin through the EKS API

- **Classification:** `DESIGN_GAP`
- **State:** `FIXED_UNQUALIFIED` — decision ratified 2026-09-19 (split identities) and implemented in #376; a run must still record that the steady-state identity's `eks associate-access-policy` attempt is denied
- **First identified:** 2026-09-19 (authority audit, this pass)
- **Last verified:** 2026-09-19, `main @ 910a59f1`
- **Provider:** AWS / EKS
- **Decision:** **split the cloud-provisioning identity from the steady-state
  cluster-access identity** (ratified 2026-09-19 by the repository owner).
  Recorded in `DEC-034`; implementation is `INFRA-046`.
- **Derived tickets:** **INFRA-046** (implementation), `DEC-034` (decision)
- **Related invariant:** `INV-AUTH-4`, `INV-AUTH-5`
- **Related decisions:** ADR 0002 (identity table — needs revision for the split), ADR 0003 (invariant 2)
- **Related:** FND-0003 (effective-capability qualification)

## Sol claim at stake

Three places state that the steady-state AWS provisioner cannot obtain more
authority than it holds:

- ADR 0003 invariant 2: "The steady-state provisioner is never
  privilege-escalatable. It holds no `escalate`/`bind` verb on
  `clusterroles`/`clusterrolebindings`. **It therefore cannot manufacture a more
  powerful identity.**"
- `docs/deployment/production-bootstrap.md:127-128`: "the steady-state provisioner
  never holds `escalate`/`bind` and cannot manufacture a more powerful identity."
- `docs/qualification/production-single-region-v1-matrix.md` (row I3): "the
  boundary is that the provisioner cannot manufacture an identity more powerful
  than itself".

The `deploy` policy is the model the provisioner does not follow: it carries an
explicit `NoInfrastructureOrIdentityMutation` deny including
`eks:CreateAccessEntry`, `eks:AssociateAccessPolicy` and `iam:*`
(`cli/platform/infra/bootstrap/main.tf:141-154`).

## Verified provider contract

- Associating an access policy requires, among others, the `AssociateAccessPolicy`
  permission: "An AWS IAM role or user with the following permissions:
  `ListAccessEntries`, `DescribeAccessEntry`, `UpdateAccessEntry`,
  `ListAccessPolicies`, `AssociateAccessPolicy`, and `DisassociateAccessPolicy`."
  — https://docs.aws.amazon.com/eks/latest/userguide/access-policies.html
- `AmazonEKSClusterAdminPolicy` "includes permissions that grant an IAM principal
  administrator access to a cluster", with the permission table `* * * * *`.
  — https://docs.aws.amazon.com/eks/latest/userguide/access-policy-permissions.html
- `aws eks associate-access-policy` performs exactly that association.
  — https://docs.aws.amazon.com/cli/latest/reference/eks/associate-access-policy.html
- Access entries can be created/managed entirely through the EKS API without
  direct Kubernetes access.
  — https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html

## Current implementation evidence

- `cli/platform/infra/bootstrap/main.tf:75-107` generates the provisioner policy
  with `"eks:*"` on `"*"` (sid `ManageClusterInfrastructure`). `eks:*` includes
  `AssociateAccessPolicy`, `CreateAccessEntry` and `UpdateAccessEntry`.
- There is no explicit deny for access-entry/policy management on the
  provisioner, unlike the deploy policy.
- The provisioner already owns an EKS access entry
  (`cli/platform/infra/aws/main.tf:153-181`), so it does not even need to create
  one — it can associate the cluster-admin policy with its existing entry.

## What is established

On AWS the Kubernetes RBAC boundary is real and is checked live
(`provisioner_authorization_checks`, positive and negative, executed after
de-escalation in every `sol cloud apply`). IAM itself does **not** grant
in-cluster rights on EKS. But the provisioner's IAM policy permits it to
*re-map* its own access entry to `AmazonEKSClusterAdminPolicy` through the EKS
control plane at any time, so the statement "cannot manufacture a more powerful
identity" is true only of the Kubernetes RBAC layer, not of the AWS authority
available to the same identity.

## What is NOT established

- No run has attempted the escalation; the live severity/possibility is
  inference from the documented permission set, not observation.
- Whether the provisioner role is ever used to apply the cloud root in the
  documented model is ambiguous: `require_credentials`
  (`cli/sol/bin/cmd_cloud_tf.ml:807`) resolves the **ambient AWS identity** for
  the cloud stage, while the provisioner role is assumed for cluster access
  (`provisioner_kubeconfig --role-arn`). `production-bootstrap.md` §2 describes
  the provisioner as the identity that "creates/updates cloud and platform
  infrastructure", and HARDEN Run 2 records the cloud apply being driven through
  an assumed `…-provisioner` role. If the cloud root is always applied by the
  provisioner, `eks:*` is *required* for its job; if it is applied by the
  operator, `eks:*` is an over-grant on the steady-state identity.

## Impact

The stated invariant is scoped to one mechanism (Kubernetes `escalate`/`bind`)
but written as a claim about the identity. A reader — or a HARDEN probe — that
takes it literally would conclude the provisioner cannot re-acquire cluster
admin, and the post-closure `can-i` checks cannot observe an AWS-API path at
all. The residual authority is real; whether it is unacceptable is a design
question.

## Classification and the decision

**Classification stays `DESIGN_GAP`.** The AWS behaviour is fully documented and
correct — `eks:AssociateAccessPolicy` is the documented permission, and
`AmazonEKSClusterAdminPolicy` is documented to grant administrator access — so
this is not a case of Sol's docs contradicting an undocumented provider fact.
The misalignment is between Sol's stated invariant ("cannot manufacture a more
powerful identity") and a design that uses one identity to both build the cluster
(and therefore manage its access entries) and act as the steady-state
cluster-access identity.

**Decision (2026-09-19, ratified): split the identities.**

- a **cloud-provisioning identity** that legitimately owns `eks:*` (and the GCP
  equivalents), because its job is to create/update the cloud substrate and the
  bootstrap access entry; and
- a **steady-state cluster-access identity** that the platform role assumes,
  which must not hold `eks:AssociateAccessPolicy`, `eks:CreateAccessEntry`,
  `eks:UpdateAccessEntry` or `iam:*`, and is the identity the post-closure
  `can-i` probe exercises.

This is the only shape in which `INV-AUTH-4` / `INV-AUTH-5` can be true on AWS as
well as GCP, and it mirrors what the deploy policy already does with its explicit
`NoInfrastructureOrIdentityMutation` deny. It supersedes ADR 0002's "no fifth
identity" for the provisioning axis; ADR 0002, the matrix row I3 wording and
`production-bootstrap.md:127-128` must be revised to match.

Recorded in `DEC-034`; the implementation work is `INFRA-046`.

## To move to qualified

Implement `INFRA-046`, then demonstrate that the steady-state cluster-access
identity cannot re-grant itself cluster-admin (the association is denied, or the
identity structurally cannot make it), and update ADR 0002 and matrix row I3 to
the split model. Until then the state stays `OPEN`; it becomes
`FIXED_UNQUALIFIED` when the code lands and `QUALIFIED` only when a run proves the
residual path is gone.

## Supersession

None.
