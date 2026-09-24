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
