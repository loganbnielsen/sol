---
id: INFRA-116
type: infra
severity: medium
source: AWS/GCP live qualification boundary audit 2026-10-05
title: Bootstrap qualification installations through Sol's supported command
---

**Depends on:** None.

## Premise verified

Both current live runners reconcile the durable, Sol-owned installation by invoking Terraform
against provider bootstrap roots directly: `internal/qualification/aws/live-row.sh` calls
`reconcile_durable_root` before `sol cloud apply`, and
`internal/qualification/gcp/live-qual.sh` does the same before its cloud phase. They run
`terraform init`, `plan` and `apply` with provider roots and vars. The supported product command
`sol cloud bootstrap <target> [--apply]` now owns and observes that installation lifecycle
(DEC-057, INFRA-096). ADR 0002's qualification boundary forbids a harness from using Terraform or
Helm to provision, repair or finish a Sol lifecycle phase. The current CI guard
`internal/ci/check_public_cloud_lifecycle.sh` still checks the legacy `live-smoke.sh` rather than
the current AWS and GCP runners, so it does not catch this duplication.

The current operating procedures describe this direct Terraform step as harness work. The
qualification harness therefore bypasses the interface an ordinary user is meant to exercise at
the installation boundary and has its own destructive-plan policy for resources that product
bootstrap now owns.

## Remediation

Have each live runner declare the qualification installation as a target input and invoke the
released Sol bundle's supported bootstrap command. Keep the target lifecycle on `sol cloud plan`,
`sol cloud apply` and `sol cloud destroy`. Keep provider API reads independent: bootstrap output or
Terraform state is not proof that the durable installation or disposable target exists or is absent.

Remove direct Terraform mutation of Sol-owned bootstrap resources from both runners. Read-only
state capture may remain when it is needed as diagnostic evidence, but it must not determine a
qualification verdict. Update the AWS/GCP run procedures and the qualification-boundary guard so
they describe and enforce the public-command path on the active harnesses. Preserve provider
specific target intent, authority declarations, independent inventory, attempt isolation, and the
cost rule.

## Acceptance criteria

- AWS and GCP live qualification use the installed release's `sol cloud bootstrap` for the
  installation and `sol cloud plan/apply/destroy` for the disposable target.
- Neither runner executes `terraform init`, `terraform plan` or `terraform apply` against a
  Sol-owned bootstrap root, and neither invokes Helm to perform a product lifecycle operation.
- Independent AWS/GCP inventory remains the authority for provider reality and post-destroy
  absence; Sol output and Terraform state alone cannot pass those rows.
- The lifecycle boundary guard covers the current AWS and GCP runners, and a mutation test fails
  if direct Terraform/Helm lifecycle mutation is reintroduced there.
- The qualification procedures match the executable invocation and distinguish durable
  installation prerequisites from disposable target resources.
- Existing provider-specific identity, DNS ownership and teardown semantics remain represented by
  their matrices; this change does not treat provider symmetry as mechanism identity.
- Example impact: none; qualification tooling. Language-parity impact: none.
