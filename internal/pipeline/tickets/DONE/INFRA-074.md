---
id: INFRA-074
type: bug
severity: medium
source: internal/pipeline/audits/2026-09-23_correctness_audit.md
---

`sol cloud apply` must not delete ECR repositories because a Dockerfile is absent from the invoking checkout

**Depends on:** None.

**Finding:** FND-0043 (`internal/pipeline/audits/findings/`).

**Premise verified 2026-09-23** against `origin/main @ f3e9480b` while filing (see the finding).

## Problem

`ecr_repositories` is derived from workloads with a Dockerfile in the current working tree; repositories have `force_delete = true` and apply runs `-auto-approve`, so running from another branch deletes repositories and images without a prompt. The `Error _ -> []` arm is the same collapse shape.

## Remediation

Before `terraform apply` on AWS, run a plan and refuse if it deletes any `aws_ecr_repository` unless `--confirm-ecr-removal` is passed (listing the repositories); make `ecr_repositories_var` propagate a discovery error instead of returning `[]`.

## Acceptance criteria

- Offline test with a plan JSON fixture deleting a repository: apply refuses without the flag, proceeds with it.
- Discovery error aborts apply.
- Demo/example: state applicability in completion notes.

## Completion notes

- `sol cloud apply` (the cloud stage, both providers) now runs from a **saved plan**:
  `terraform plan -out`, then `terraform show -json` of that file, then the check, then
  `terraform apply <file>`. What runs is what was read. If the plan deletes or
  replaces any `aws_ecr_repository`, the command refuses before any change and names
  the repositories, unless `--confirm-ecr-removal` is passed. A refusal changes nothing:
  the plan creates nothing and the bootstrap window is not open yet.
- `Sol_cli_terraform_plan.removed_of_type` (pure) returns the deleted or replaced
  addresses of a type. A replace in either ordering counts, since the repository is
  destroyed first.
- `ecr_repositories_var` no longer turns a discovery error into `[]` (an instruction to
  delete every repository). A resolved workspace with no `app/` legitimately has no
  repositories (`[]`), and any other discovery error fails `terraform_vars`.
- Tests: `test_terraform_plan.ml` (`removed_of_type`: delete, both replace orderings,
  update/create and other types excluded), `test_config.ml` (no `app/` → `[]`; only
  workloads with a Dockerfile get a repository). The offline harness adds an
  `ECR_REMOVAL=1` fixture: without the flag the apply refuses, names `old-svc` and runs
  no `terraform apply`; with it, the saved plan is applied.
- Mutation checks (`audits/README.md`), builds rc=0: forcing the refusal branch off
  fails the harness ("went ahead with a plan that deletes an ECR repository"); dropping
  `Replace` from `removed_of_type` fails its unit test.
- Docs: `docs/guides/TUTORIAL.md` (cloud apply section) explains the guard and the flag.
- Demo/example: the CLI surface gains a flag that is documented in the tutorial. No
  example workspace changes, since examples do not run `sol cloud apply`.
- Language parity: no language-parity impact (CLI/infra only).
