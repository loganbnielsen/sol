---
id: REFAC-100
type: refactor
severity: medium
title: Provider-mirrored cloud roots over a backend-free shared platform module
source: internal/pipeline/audits/2026-09-25_organization_proposal.md, rules 3–4
premise: "test -d platform/cloud/aws/bootstrap"
---

**Depends on:** REFAC-099.

**Proposal:** `internal/pipeline/audits/2026-09-25_organization_proposal.md`, rules 3–4 and § Moves.

**Premise verified (2026-09-25):** `cli/platform/infra/base/main.tf:20` declares `backend "s3" {}`, so the shared definition is also the AWS root; `base-gcp` wraps it only to get a GCS backend; `bootstrap` is AWS-only with no suffix; `argocd/` and `ci/` are templates, not roots.

## Remediation

- `infra/base` → `cloud/modules/platform`, with the `backend` block removed so it is a pure module.
- A new `cloud/aws/platform` root declares the S3 backend and calls the module, the same way `base-gcp` does today. `infra/base-gcp` → `cloud/gcp/platform`.
- `infra/{aws,gcp}` → `cloud/{aws,gcp}/cluster`. `infra/bootstrap` → `cloud/aws/bootstrap`, and `infra/bootstrap-gcp` → `cloud/gcp/bootstrap`.
- `infra/{argocd,ci}` → `cloud/delivery/{argocd,ci}`.
- Add the variable-mirroring check that `cli/platform/infra/base-gcp/variables.tf:13` says exists but doesn't: `rg -n --hidden -g '!.git' check_platform_root_wrapper` matches only that comment, and `ls internal/ci` has no such script. Every provider's `platform` root must pass through every module variable, and the check should cover all providers, not just GCP. Fix the comment to name the real script.
- Add a CI check for rule 4, driven by the registry rather than `ls`. Every provider in `Sol_cli_provider.all` has the `bootstrap`, `cluster` and `platform` roots. Every directory under `platform/cloud/` other than `modules/` and `delivery/` is a registered provider. The role list lives in one place. Registering a new provider (the Azure-on-paper surface, `2026-09-25_cloud_lifecycle_end_state.md` § S11) is what makes the check demand its roots, so a third provider never needs the check renegotiated.
- Update the provider capability records in `cli/lib` that name root directories, and every doc path.

## Acceptance criteria

- `ls platform/cloud/aws platform/cloud/gcp` list the same roots.
- The mirror check fails when a registered provider is missing a root, and when a directory under `platform/cloud/` isn't a registered provider. Both are covered by mutation tests in the style of `internal/ci/test_*.sh`.
- `sol cloud plan` for an AWS and a GCP target renders the same Terraform as before the move. Show it with a before/after `terraform plan` or the offline lifecycle test (`internal/ci/test_cloud_lifecycle_offline.sh`).
- **State migration:** moving an existing AWS `base` root into `cloud/aws/platform` + module changes resource addresses (`helm_release.x` → `module.platform.helm_release.x`). Ship `moved` blocks so an existing state plans with no destroy/create, and prove it with a plan against a state fixture.
- `rg -n --hidden -g '!.git' '<old path>'` returns nothing outside `internal/pipeline/` and dated historical records. Put the exact commands and their empty output in the completion notes.
- `dune build`, `dune test cli/` and `internal/ci/check_ocamlformat.sh --all` pass, and CI is green.

## Completion notes (required)

- Demo/example: not applicable (repository layout; no change to what an app author writes) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`.
