# FND-0002 — AWS provisioner can re-grant itself cluster-admin through the EKS API

- **Classification:** `DESIGN_GAP`
- **State:** `OPEN` (decision required: narrow the provisioner role, or split the cloud-provisioning identity from the steady-state cluster-access identity)
- **First identified:** 2026-09-19 (authority audit, this pass)
- **Last verified:** 2026-09-19, `main @ 910a59f1`
- **Provider:** AWS / EKS
- **Derived ticket:** none — see "Why no ticket"
- **Related invariant:** `INV-AUTH-4`, `INV-AUTH-5`
- **Related decisions:** ADR 0002 (identity table), ADR 0003 (invariant 2)
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
- `docs/qualification/production-single-region-v1-matrix.md:177` (row I3): "the
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

## Classification and why no ticket

**Classification: `DESIGN_GAP`, not `DOCUMENTATION_GAP` or `OBSERVATION`.**
The AWS behaviour is fully documented and correct — `eks:AssociateAccessPolicy`
is the documented permission, and `AmazonEKSClusterAdminPolicy` is documented to
grant administrator access. So this is not a case of Sol's docs contradicting an
undocumented provider fact. What is unresolved is *Sol's intended steady-state
authority contract*: ADR 0003 / `production-bootstrap.md` / matrix I3 state the
provisioner "cannot manufacture a more powerful identity", while the design
deliberately uses one identity that both builds the cluster (and therefore
manages its access entries) and is the steady-state cluster-access identity. The
stated invariant and the design are misaligned, and closing that gap requires a
design decision. `OBSERVATION` would understate the open question; a
`DOCUMENTATION_GAP` would misattribute it to the provider documentation.

The ticket policy requires a concrete, actionable implementation defect. Here
the two candidate fixes both require a decision rather than a mechanical change:

1. **Narrow the provisioner** — deny `eks:AssociateAccessPolicy` /
   `eks:CreateAccessEntry` / `eks:UpdateAccessEntry` unless the identity is
   actually applying the cloud root. This may break the documented model where
   the provisioner applies the cloud root and creates the bootstrap association.
2. **Split the identities** — one cloud-provisioning identity that owns
   `eks:*`, and one steady-state cluster-access identity that does not. The
   current design deliberately uses one ("no fifth identity", ADR 0002;
   inventory: "splitting cloud and platform provisioners is unnecessary until
   trust owners differ").

Either is a `DEC-*` / ADR-level choice. Creating an `INFRA-*` ticket now would
prescribe a fix to an undecided question. Whichever way it is decided, the
outcome is recorded on this finding as a state transition (`OPEN` →
`FIXED_UNQUALIFIED` → `QUALIFIED`, or `OPEN` → `ACCEPTED`), never by rewriting
the classification.

## To move to qualified

Decide 1 or 2. Then, whichever is chosen, demonstrate the residual capability
(either denied after closure, or explicitly accepted with a named compensating
boundary) and record it in the matrix row I3 wording.

## Supersession

None.
