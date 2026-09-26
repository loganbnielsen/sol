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

## Completion notes

**Premise re-verified (2026-09-25, `origin/main` after REFAC-099):** `platform/infra/base/main.tf` declared `backend "s3" {}` and was the AWS root; `base-gcp` wrapped it for GCS; `bootstrap` had no provider suffix.

**Layout.** Everything is under `platform/cloud/`:
- `modules/platform` is the former `base`, with no backend and its components path one level deeper;
- `aws/{bootstrap,cluster,platform}` and `gcp/{bootstrap,cluster,platform}`;
- `delivery/{argocd,ci}`.

The new `aws/platform` root has the S3 backend, declares every module variable (all 44, including the two in `cert_manager_issuer.tf`), passes each through, and passes through all 6 outputs. `terraform validate` passes on both platform roots, and `terraform fmt -check -recursive platform/cloud` is clean.

**State migration: the `moved` blocks, proven offline.** `aws/platform` has one `moved { from = T.N  to = module.platform.T.N }` per module resource (45 of 45). The proof, run with an empty kubeconfig so nothing could reach a cluster:
1. **Old addresses.** Planning `origin/main`'s old `base` as a root against empty state gives 39 creates, the default shape.
2. **Fixture.** A state holding exactly those 39 instances at their old top-level addresses was built from that plan's planned values, with provider schema versions from `terraform providers schema -json`.
3. **New root.** Planning `aws/platform` against that state: **39 of 39 instances moved** (`previous_address` X → `module.platform.X`), **0 creates, 0 deletes**, 12 updates and 27 no-ops.
4. **Control.** Planning the unmoved old root against the same fixture gives the **identical 12 updates**. They come from the synthesized fixture, not the move.

The two `kubernetes_manifest` ClusterIssuers need a live API server even at plan time, so they were excluded from the Terraform run. They use the same mechanism, and the static 45/45 check covers them.

**Code.**
- **Root and address prefix are one rule now.** `Sol_cli_cloud_lifecycle.platform_root` is `platform/cloud/<provider>/platform`, and `platform_address` is `module.platform.<address>` for every provider. The `platform_root` / `platform_address` capability fields are removed, since a value identical for all providers isn't a capability.
- **Cluster roots:** `cmd_cloud_tf.infra_dir` resolves `platform/cloud/<provider>/cluster`.
- **Operation-record keys changed.** They're now prefixed `<provider>-<role>` (`aws-cluster-…`, `gcp-platform-…`). A bare basename would have been `cluster` or `platform` for every provider. Because the digest includes the root's path, a record written before this move (or before REFAC-099) is not found afterwards. That was already true of REFAC-099; pre-alpha, noted rather than shimmed.

**One provider list.**
- `Sol_cli_provider.all` is exhaustive by construction: a `next` successor match walked from `Aws`.
- **Throwaway mutation:** adding an `Azure` constructor with `to_string`/`of_string` arms but no `next` arm fails the build: "Error (warning 8 [partial-match]): this pattern-matching is not exhaustive. Here is an example of a case that is not matched: Azure".
- `cli/test/print_providers.exe` prints the list. `internal/ci/providers.sh` reads it for shell guards, fails closed when it isn't built, and takes `SOL_PROVIDERS` as an override for mutation tests.
- `check_destroy_completeness.sh` no longer scrapes `let to_string` with `sed`. `rg -n 'sed -n .*/\^let to_string/' internal/ci` → nothing. It also now fails when no provider has a cluster root; that case used to pass. Its mutation test gained a fail-closed case.

**Rule-4 guard.** `internal/ci/check_provider_roots.sh` ("the directory is the marker") and `test_provider_roots.sh` are wired into CI with Build's `docs-only` condition, because they read the built printer. Mutation cases:
- a missing role, and a role directory with no `.tf` → **fail**;
- an unregistered directory, and a registered-but-half-built provider → **fail**;
- no provider with roots, and an unreadable list → **fail**;
- a registered provider with no directory (S11) → **passes**.

**Correction to the proposal and this ticket.** Both said the variable-mirroring check `base-gcp`'s comment cites doesn't exist. That's wrong. The comment named a script that doesn't exist (`check_platform_root_wrapper.sh`), but the check itself was in `cli/test/check_production_infra.sh`, as `docs/qualification/gcp-bootstrap-inventory.md:670` says. The original search looked for the script name without a positive control. Here the existing check is generalized rather than duplicated: one loop checks every provider's platform root for its backend type, the declared-variable mirror, and **pass-through** in `main.tf` (new), and it asserts the module declares no backend. Controls on a full copy of the tree: removing a variable, removing a pass-through line, or restoring the module's backend each fail with their own message; the unmodified copy passes. The stale comment now names the real check.

**Other fixes the move required:**
- `check_qualification_transport.sh` scans `platform/cloud/*/*/`;
- the offline lifecycle test's fake-`terraform` dispatch uses explicit per-root patterns, not `*cloud/*/platform*`, which could span arguments;
- three AWS `-target=` assertions gained the module prefix;
- two places where the mechanical rename had turned "the AWS root" into the module path were corrected.

**Residual risk:** the provider list is authoritative only through `Sol_cli_provider.all`. `rg -n 'Aws; Gcp|"aws"; "gcp"' cli --glob '*.ml'` found one other hand-written enumeration, `[ "aws"; "gcp" ]` in `test_sensitive_vars.ml`'s "refused on both providers" test. It now derives the providers that have a cluster root from `Sol_cli_provider.all`, requires at least one, and its rule depends on all of `platform/cloud` so a new provider's root is visible. After that change the search returns nothing.

**Verified:**
- `dune build` and `dune test cli/test/` pass (0 `[FAIL]`, including the offline lifecycle suite);
- every `internal/ci/check_*.sh` and `test_*.sh` passes;
- the harness tests pass;
- `check_ocamlformat.sh --all` is clean.

**Demo/example:** not applicable; this is repository layout and cloud-root structure, with no change to what an app author writes. **Language parity (DEC-022):** no application-facing impact.
