---
id: INFRA-026
type: bug
severity: high
title: Add the missing publisher IAM policy contract (HARDEN-002 finding 6)
source: HARDEN-002 run 2 finding 6; ADR 0002
---

**Depends on:** None.

**Related:** HARDEN-002 (finding 6), ADR 0002 (identity table), AUDIT-072
(the provisioner/deploy/operator contract this completes), INFRA-024
(verified the OCaml *code-path* separation; this ticket is the AWS IAM
half that INFRA-024 explicitly did not cover).

## Premise

`grep -rn 'ecr:' cli/platform/infra/aws/*.tf` had zero matches, yet
`cli/platform/infra/aws/main.tf` declares `aws_ecr_repository.services` — the
provisioner's own terraform creates repositories it has no policy permission
to manage, and no identity in the bootstrap-generated contract
(`provisioner_policy_json`/`deploy_policy_json`/`operator_policy_json`) could
push an image into one. HARDEN-002 run 2 recorded the resulting deviation:
"images were published with the operator's own credential, a broader
identity than the contract names."

## Working through the mechanism (not just checking the acceptance criteria)

`internal/qualification/aws/smoke-test-iam-policy.json` — the qualification
harness's own scoped runner identity, not one of the three contract roles —
already carries `ecr:PutImage` and friends. That's not a fix; it's the same
deviation recorded a different way (a fourth, undocumented, ad hoc identity
standing in for a missing one).

Two questions had to be answered before writing any policy, not just one:

1. **Does the provisioner need any ECR permission at all?** Yes —
   independent of the publish question, its own terraform declares
   `aws_ecr_repository.services`, so it needs repository *lifecycle* actions
   (create/describe/tag/lifecycle-policy) regardless of who publishes into
   them. This part of finding 6 was really a separate, pre-existing gap
   (the provisioner couldn't even manage what it creates), not the publish
   boundary itself.
2. **Can the provisioner also get the publish (data-plane) actions, since
   it's already the identity managing the repos?** No — ADR 0002 states
   "provisioner must not publish images" as an explicit boundary, not a
   judgment call. Bundling `ecr:PutImage` onto the provisioner would
   directly violate an already-decided invariant, not merely be
   inconsistent with it. This ruled out the "just extend the provisioner"
   option HARDEN-002's finding 6 raised as if it were open.
3. **Who does need the publish actions?** ADR 0002's identity table already
   names a fourth identity — "publisher: publish/replace application
   images; must not provision substrate or deploy workloads" — the
   bootstrap root simply never generated a policy contract for it. Adding
   `data.aws_iam_policy_document.publisher` completes an identity the
   architecture already named, the same relationship INFRA-025 had to
   `deploy_role_arn` (a field that existed before anything wired it up).
4. **Does Sol's own execution need to resolve a `publisher_role_arn` target
   field, mirroring `deploy_role_arn`?** No — checked `cmd_up.ml` directly:
   `sol up` is explicitly "Local-only — no target concept," so it never
   touches AWS/ECR at all. Production image publishing happens entirely in
   a CI pipeline's own `docker push` step, outside any Sol code path, before
   `sol deploy` is invoked with the resulting digest. So unlike
   `deploy_role_arn` (which `Sol_cli_destination.resolve` actually reads),
   a `publisher_role_arn` would have no runtime consumer — adding a target
   field for it would be an inert schema addition nothing reads, which is
   why this ticket does not add one. The publisher contract is
   policy-generation output only, for the operator's own CI configuration.

## What changed

- `cli/platform/infra/bootstrap/main.tf`: provisioner gains ECR
  repository-lifecycle actions (`CreateRepository`/`DescribeRepositories`/
  `PutLifecyclePolicy`/etc.) plus an **explicit Deny** on the ECR data-plane
  actions (`PutImage`, `InitiateLayerUpload`, `GetAuthorizationToken`, ...) —
  a structural boundary, not an omission a future broader attachment could
  silently restore. A new `publisher` policy document grants exactly those
  data-plane actions, with its own explicit Deny on infrastructure/IAM/
  repository-lifecycle mutation (mirroring `deploy`'s existing deny-block
  pattern), so publishing an image cannot also grant provisioning or deploy
  authority.
- `cli/platform/infra/bootstrap/outputs.tf`: new `publisher_policy_json`
  output.
- `docs/deployment/production-bootstrap.md` §2: documents all four
  identities now, explicit about which three ARNs `sol deploy` actually
  reads (unchanged) versus the publisher contract, which nothing in Sol
  resolves.
- Added the bootstrap root's `.terraform.lock.hcl` (missing before this
  change; the aws/base roots already track theirs — an existing gap this
  ticket's own `terraform init`/`validate` run surfaced, not introduced by
  it).

## Offline evidence

`cli/sol/test/check_production_infra.sh` gained structural assertions:
the provisioner policy's explicit `PutImage` deny; the publisher policy's
existence, its `PutImage` grant, and its explicit provisioning/IAM deny; the
`publisher_policy_json` output. Wiring these into `dune test` surfaced an
existing dune-deps bug — the `runtest` rule declared `source_tree` for the
`aws`/`base` roots but never `bootstrap`, so the script's own reads of
`bootstrap/main.tf` failed inside dune's sandbox even though it worked when
run directly (`bash cli/sol/test/check_production_infra.sh $(pwd)`). Fixed
in `cli/sol/test/dune` alongside this change.

## Not in scope

- Live verification that the publisher policy's denies/allows actually hold
  against a real AWS account, or that a CI pipeline's own role-assumption
  flow works end to end — HARDEN run 3, per this pass's instructions not to
  promote offline policy-shape evidence into a live qualification claim.
- A `publisher_role_arn` target field or any Sol-side runtime change — not
  needed, per the mechanism analysis above, and not invented here.

**Demo/example coverage:** not applicable — this changes the bootstrap
root's generated IAM contracts, not a primitive, CLI surface, or generated
manifest an app author writes against.

**TypeScript parity:** not applicable — target provisioning and IAM policy
generation are language-neutral (DEC-022).
