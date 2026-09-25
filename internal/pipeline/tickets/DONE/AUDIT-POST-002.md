---
id: AUDIT-POST-002
type: audit-finding
severity: medium
source: internal/pipeline/audits/2026-09-25_cloud_lifecycle_post_audit.md
---

The generic apply sequence knows the AWS ECR resource type

**Depends on:** None.

**Related:** INFRA-074, FND-0043, REFAC-091, AUDIT-POST-003

**Plan:** `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`,
§ Directions ("generic lifecycle code does not depend on provider-native types") and § S7.

## Problem

`Sol_cli_cloud_apply.ml` — the generic install sequence — hard-codes a provider resource type and an
ECR-shaped refusal:

- `:74` `Sol_cli_terraform_plan.removed_of_type ~resource_type:"aws_ecr_repository"`;
- `:34` the deps record carries `confirm_ecr_removal : bool`;
- `:72-94` the refusal message speaks of ECR repositories and their images.

## Root cause

INFRA-074's image-loss guard was correct and had to be preserved, but when the install half was
ported to a result-returning `execute ~deps` (REFAC-091) the check moved into the generic sequence
instead of behind the provider capability seam the rest of the program established. The check came
from `cmd_cloud_tf.ml`, so its provider-specificity was less visible there.

## Impact

The generic sequence enforces a Sol semantic ("a destructive removal that needs explicit
confirmation is refused before apply") by knowing which Terraform type means that *on AWS*. GCP
declares `google_artifact_registry_repository.images` (`cli/platform/infra/gcp/main.tf:128`) and gets
no equivalent check, and a new provider inherits nothing. The AWS protection itself still works.

GCP's risk shape genuinely differs (its repository has no `force_delete`, so a deletion that would
discard images fails rather than proceeding), which is why this is a boundary defect rather than a
data-loss defect — and why the fix must not force symmetry.

## Remediation

Put the provider-specific resource-type knowledge behind the existing capability boundary, as the
smallest data-shaped datum that the generic sequence can iterate.

- Add to `Sol_cli_provider_capabilities.t` a field naming the resource types whose removal during an
  apply is destructive enough to require explicit confirmation (AWS: `aws_ecr_repository`; GCP: `[]`,
  with a comment saying why it is empty rather than pretending to a mechanism it does not have).
- Keep the generic semantic in `Sol_cli_cloud_apply`: iterate the provider's list, and refuse when
  the plan removes any of them unless the confirmation dependency is set. The generic refusal text
  should name the resource addresses, not the provider's product name.
- Preserve the user-facing confirmation contract: the existing flag and its behaviour stay.
- Do not introduce a generic cloud-resource identity model, and do not add a registry of provider
  Terraform resource types beyond this one datum.

## Acceptance criteria

- `Sol_cli_cloud_apply.ml` contains no `aws_ecr_repository` literal and no ECR-specific text
  (`rg -n 'ecr' cli/sol/lib/sol_cli_cloud_apply.ml` returns nothing).
- AWS keeps its image-loss protection: the offline harness's ECR-removal scenario still refuses
  without the flag and proceeds with it.
- GCP is not forced into a false equivalent (its capability lists none, with a stated reason).
- Generic apply tests establish the sequencing/refusal; a provider test establishes which
  provider-specific removal is guarded.
- A new provider that declares no such types inherits "nothing is guarded", never AWS's list.

## Completion notes (2026-09-25)

**Problem.** `Sol_cli_cloud_apply.check_ecr_removal` carried the literal
`resource_type:"aws_ecr_repository"` and an ECR-worded refusal, in a module whose whole premise
(refactor-plan decision 3) is that every provider-specific step arrives as a dependency. It was the
one provider fact in the generic apply sequence.

**Root cause.** INFRA-074 added the guard where the sequencing already lived, because at that moment
the only provider with the problem was AWS and the check was three lines. Nothing moved it when the
provider boundary was drawn around everything else.

**Change — the "guarded removals" datum.** A capability field
(`Sol_cli_provider_capabilities.t.guarded_removals : string list`) says which resource types discard
something a re-apply cannot restore:

- AWS: `[ "aws_ecr_repository" ]`, with why (derived from the workloads in the invoking checkout, and
  `force_delete = true`);
- GCP: `[]`, with why — an Artifact Registry repository cannot be deleted while it holds images, so
  the provider refuses the deletion itself. That is a different risk shape, not a missing guard, and
  it is stated rather than faked.

`check_guarded_removals` iterates that list through the existing
`Sol_cli_terraform_plan.removed_of_type` and keeps the policy (refuse before anything is applied
unless confirmed). The confirmation *flag's* spelling is passed in as `confirmation_flag`, so the
sequence does not carry a provider product's name in a message either. `Sol_cli_cloud_apply.ml` now
has no ECR text at all.

**Preserved contract.** The CLI flag is still `--confirm-ecr-removal` (`cmd_cloud_tf.ml` defines its
name once and passes it), so existing docs and scripts keep working; the flag is the user-facing
contract the ticket asked not to churn.

**Executable evidence.**
- `rg -n 'ecr' cli/sol/lib/sol_cli_cloud_apply.ml` returns nothing.
- `cli/sol/test/test_cloud_apply.ml` now declares its own `test_guarded_kind` rather than an AWS
  type — the sequence is data-driven — and gains `test_unguarded_provider_is_unaffected`: the same
  destructive plan *is* applied when the provider declares no guarded type, which is the "a new
  provider inherits nothing" criterion.
- The offline harness's ECR scenario still refuses without the flag, names the address, names the
  reason and the flag, and still applies the saved plan when `--confirm-ecr-removal` is given (its
  assertions were updated from the old ECR-worded sentence to the generic one).
- `dune build`, `dune test cli/sol/test/`, the offline harness and the CI guards pass; the
  provider-dispatch count is unchanged.

**Canonical merge SHA.** The squash commit that moved this ticket to `DONE/`; recover it with
`git log --oneline -1 -- internal/pipeline/tickets/DONE/AUDIT-POST-002.md`.

- Demo/example: not applicable (cloud lifecycle internals); the observable CLI contract is unchanged.
- Language parity (DEC-022): no application-facing impact.
