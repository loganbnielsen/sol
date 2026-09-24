# FND-0043 — ECR repository existence is derived from the invoking checkout, and applied with `-auto-approve` and `force_delete`

- **Classification:** `DESIGN_GAP`
- **State:** `OPEN`
- **First identified:** 2026-09-23, correctness audit
- **Last verified:** 2026-09-23 (`origin/main @ f3e9480b`)
- **Derived ticket:** `INFRA-074`
- **Evidence class:** `STATIC`

## What is established

- `ecr_repositories_var` (`cli/sol/lib/sol_cli_config.ml:1306`) builds the AWS root's
  `ecr_repositories` from `discover_services_result`, which keeps only workloads with
  a Dockerfile in the invoking checkout (`sol_cli_manifest.ml:105`, `has_dockerfile full`).
  A discovery `Error` becomes `[]`. That arm is effectively unreachable here, because
  `load_for_target` has already resolved the same workspace, but the shape is the
  FND-0024 collapse.
- `aws_ecr_repository.services` is `for_each = toset(var.ecr_repositories)` with
  `force_delete = true` (`cli/platform/infra/aws/main.tf:204-223`, INFRA-037).
- `sol cloud apply` runs `terraform apply -auto-approve` (`sol_cli_terraform.ml:66`) and
  inspects no plan for deletions.

Together: the set of **cloud repositories, and every image in them**, is a function of
which directories under `app/` contain a Dockerfile *on the machine and branch running
`sol cloud apply`*. Running it from a branch that predates a service, or one where a
Dockerfile was moved or renamed, destroys that service's repository and images with no
prompt. INFRA-037's reasoning (lifecycle-produced artifacts must be removable by the
lifecycle) is sound for `destroy`. It does not cover an `apply` that removes a
repository because a file is absent from one checkout.

## Impact

Medium. Irreversible artifact loss triggered by working-tree state, through a command
operators treat as infrastructure-only.

## Decision needed

Options: derive repositories from a durable record (the deploy/release state), not the
working tree; make removal from `ecr_repositories` require explicit confirmation (plan
check before apply); or let `sol deploy` create repositories on demand and let only
`destroy` remove them.

## Related

INFRA-037 (`force_delete`); FRIC-011 (repository naming); HARDEN-002.
