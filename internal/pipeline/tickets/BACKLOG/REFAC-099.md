---
id: REFAC-099
type: refactor
severity: medium
title: Separate code from assets — lift cli/platform to platform/ and cli/sol to cli/
source: internal/pipeline/audits/2026-09-25_organization_proposal.md, rule 2
premise: "test -d platform/local"
---

**Depends on:** DEC-046.

**Proposal:** `internal/pipeline/audits/2026-09-25_organization_proposal.md`, rule 2 and § Moves.

**Premise verified (2026-09-25):** at `origin/main` `1aad2623`, `ls cli/` shows `platform` and `sol`, and there is no top-level `platform/`.

## Remediation

- `git mv cli/platform platform`.
- Move `cli/sol/{bin,lib,test}` to `cli/{bin,lib,test}`, and `cli/sol/control_plane_migrations` to `cli/migrations`.
- Update every consumer of both paths in the same change: SOL_HOME resolution (`Sol_cli_cmd_new.infer_sol_home` and every `Filename.concat sol_home "cli/platform/…"`), Terraform `local.platform_components_dir`, `internal/ci/` (about 20 scripts, e.g. `check_destroy_completeness.sh`, `check_gcloud_interface.sh`, `check_operator_diagnostics.sh`, `test_hook_install.sh`, `test_cloud_lifecycle_offline.sh`), **`internal/ci/provider_dispatch_allowlist.txt`** (a path-keyed data file, e.g. `dispatch cli/sol/lib/sol_cli_config.ml 1 …`, read by `check_provider_dispatch.sh`; it's data, so a script-by-script sweep misses it), `.github/workflows/`, the hooks, `AGENTS.md`, `CONTRIBUTING.md`, and docs. That includes the binary path `_build/default/cli/sol/bin/main.exe`.

This is the first move so that the later platform tickets change each path only once. **It lands as two commits or PRs:** `cli/platform` → `platform/` first, then `cli/sol` → `cli/`, so the two repo-wide diffs aren't tangled together.

**CI consumers that must move in the same commit.** These fail loudly rather than silently, but if they're missed CI goes red for the wrong reason:

- `_build/default/cli/sol/bin/main.exe` / `dune build cli/sol/bin/main.exe`: `ci.yml:474,512,1079,1101`, `release.yml:53,60`, `fn-svc-isolation-spike.yml:76`.
- `bash cli/platform/local/scripts/…`: `ci.yml:172,470,1075`, `workspace-independence.yml:69,72`.
- **The one silent consumer:** the `paths:` filter at `workspace-independence.yml:26`. If it stops matching, the workflow stops triggering rather than failing.

Line numbers are as of `origin/main` `50449a1a`; re-run `rg -n 'cli/(platform|sol)' .github/workflows/` when starting.

## Acceptance criteria

- `cli/` holds the binary and what it needs (OCaml, dune files, the SQL migrations under `cli/migrations/`, test scripts) and no platform assets: no Helm values, Terraform or templates. `platform/` contains no OCaml.
- A CI check fails when any path in a workflow `paths:` filter doesn't exist, with a mutation test in the style of `internal/ci/test_*.sh`. **What "exists" means:** a literal entry (`cli/platform/local/scripts/prove-workspace-independence.sh`) must exist as a file. A glob entry (`examples/**`) must have its literal prefix, the path before the first `*`, `?` or `[`, exist as a directory, and at least one tracked file must match it (`git ls-files -- '<glob>'` is non-empty).
- `rg -n --hidden -g '!.git' '<old path>'` returns nothing outside `internal/pipeline/` and dated historical records. Put the exact commands and their empty output in the completion notes.
- `dune build`, `dune test cli/` and `internal/ci/check_ocamlformat.sh --all` pass, and CI is green.

## Completion notes (required)

- Demo/example: not applicable (repository layout; no change to what an app author writes) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`.
