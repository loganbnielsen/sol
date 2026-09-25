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
- Add a CI check for rule 4 ("the directory is the marker"; see the proposal). The role list lives in one place.
  - A registered provider with no `platform/cloud/<provider>/` directory is on paper, and passes.
  - A registered provider with that directory has every role.
  - Every directory under `platform/cloud/` other than `modules/` and `delivery/` is a registered provider.

  Registering a provider alone must stay legal; that's the S11 technique (`2026-09-25_cloud_lifecycle_end_state.md` § S11).
- **One provider list.** Make `Sol_cli_provider.all` exhaustive by construction, so adding a constructor to `Sol_cli_provider.t` without placing it in `all` fails the build. Add a printer executable for shell guards, following `cli/sol/test/print_readiness_invocations.ml` → `check_readiness_invocations.sh`. Switch `check_destroy_completeness.sh` from its `sed` scrape of `let to_string` (line 33) to that printer, and point its root paths (`cli/platform/infra/$provider`, line 41) at `platform/cloud/$provider/`. The rule-4 guard reads the same printer.
- The three provider modules have distinct jobs. Name each correctly in code comments and docs: `Sol_cli_provider` (the type, `to_string`, `all`), `Sol_cli_provider_capabilities` (`capabilities_of`, the per-provider capability record), and `Sol_cli_provider_registry` (the per-root dispatch: `of_root`, `destruction`, `credentials`).
- Update the provider capability records in `cli/lib` that name root directories, and every doc path.

## Acceptance criteria

- `ls platform/cloud/aws platform/cloud/gcp` list the same roots.
- The rule-4 check has mutation tests in the style of `internal/ci/test_*.sh` for all three cases:
  - a provider with a directory but a missing role **fails**;
  - an unregistered directory under `platform/cloud/` **fails**;
  - a registered provider with no directory **passes**.
- `rg -n 'sed -n .*/\^let to_string/' internal/ci` returns nothing. No guard derives the provider list by scraping source.
- Adding a constructor to `Sol_cli_provider.t` without adding it to `all` fails `dune build`. Show it with a throwaway mutation, not just an argument.
- **Residual risk, stated in the completion notes:** anything that still enumerates providers some other way. List them, or state that `rg -n 'Aws; Gcp|"aws"; "gcp"'` finds none outside `Sol_cli_provider`.
- `sol cloud plan` for an AWS and a GCP target renders the same Terraform as before the move. Show it with a before/after `terraform plan` or the offline lifecycle test (`internal/ci/test_cloud_lifecycle_offline.sh`).
- **State migration:** moving an existing AWS `base` root into `cloud/aws/platform` + module changes resource addresses (`helm_release.x` → `module.platform.helm_release.x`). Ship `moved` blocks so an existing state plans with no destroy/create, and prove it with a plan against a state fixture.
- `rg -n --hidden -g '!.git' '<old path>'` returns nothing outside `internal/pipeline/` and dated historical records. Put the exact commands and their empty output in the completion notes.
- `dune build`, `dune test cli/` and `internal/ci/check_ocamlformat.sh --all` pass, and CI is green.

## Completion notes (required)

- Demo/example: not applicable (repository layout; no change to what an app author writes) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`.
