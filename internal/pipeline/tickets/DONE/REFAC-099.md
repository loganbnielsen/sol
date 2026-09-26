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
- Update `internal/planning/WORK_SUMMARY.md`.

## Progress

**Part A (`cli/platform` → `platform/`), 2026-09-25.**
- `git mv cli/platform platform`. Every live reference was rewritten: 115 files, excluding `internal/pipeline/` and dated qualification/audit/dogfood records, which stay as written.
- **Depth fixes a text replacement can't make:**
  - five scripts that reach the repo root with `$SCRIPT_DIR/../../../..`, now `../../..` (`run_tests.sh`, `perf.sh`, `install-hooks.sh`, `prepare-framework-deps.sh`, `prove-workspace-independence.sh`);
  - `cli/sol/test/dune`'s `(source_tree ../../platform/…)`, now `../../../platform/…`;
  - `test_sensitive_vars.ml`'s `"../../platform/infra"`.

  Relative paths *inside* `platform/` (`../base`, `../../components`, `../config`) point at siblings and didn't change.
- **New guard:** `internal/ci/check_workflow_paths.sh`, with the mutation test `test_workflow_paths.sh`, wired unconditionally into `ci.yml`. Literal entries must exist. A glob's directory prefix must exist and it must match a tracked file (`git ls-files -- ':(glob)…'`). `!` entries are exempt. Positive control: pointing `workspace-independence.yml:26` back at `cli/platform/…` fails it with the file and line.
- **Verified:**
  - `dune build` and `dune test cli/sol/test/` pass (0 `[FAIL]`);
  - every `internal/ci/test_*.sh` passes;
  - the platform-reading guards pass (`check_platform_component_drift`, `check_destroy_completeness`, `check_provider_dispatch`, `check_gcloud_interface`, `check_operator_diagnostics`, `check_gcp_provisioner_role`, `check_cluster_access_identity`, …);
  - `platform/local/scripts/lib/port-preflight_test.sh` and `internal/qualification/gcp/test-{live-qual,verify-matrix}.sh` pass.
- **Remaining references, all intentional:** dated records; the mutation test's dead fixture paths; and the `note` string in `internal/tooling/perf/perf_baseline.json`, which is main-only by policy (REFAC-078) and so is left for a baseline update on `main`.

Part B (`cli/sol` → `cli/`) follows as its own PR.

**Part B (`cli/sol/*` → `cli/*`), 2026-09-25.**
- `cli/sol/{bin,lib,test}` → `cli/{bin,lib,test}`, and `cli/sol/control_plane_migrations` → `cli/migrations`. 57 live files that named `cli/sol/` were rewritten; the binary is now `_build/default/cli/bin/main.exe`.
- **Depth fixes:** `cli/test/dune`'s `source_tree` and `internal/ci` dependencies (`../../../` → `../../`); `test_sensitive_vars.ml`; and `test_config.ml`'s build-directory route to pluto (5 → 4 levels). `check_production_infra.sh` receives `%{workspace_root}`, so depth doesn't affect it.
- **Verified:**
  - `dune build` and `dune test cli/test/` pass (0 `[FAIL]`);
  - every `internal/ci/check_*.sh` and `test_*.sh` passes;
  - `check_ocamlformat.sh --staged` is clean;
  - `rg -l --hidden -g '!.git' 'cli/sol/'` outside `internal/pipeline/` and dated records returns nothing.

  The one remaining slash-less `cli/sol` is a historical rename note in `WORK_SUMMARY.md` (`cli/sun -> cli/sol`), left as written.
- **Found, not acted on:** `cli/migrations/{001_hosted_control_plane,002_hosted_release_digest}.sql` are unreferenced. `rg -n --hidden -g '!.git' '001_hosted_control_plane|002_hosted_release_digest|control_plane_migrations'` matches only this ticket and the proposal, and `git log` shows no change since the history baseline. Nothing the binary runs needs them. Deleting them is a product call, so they're moved as the ticket specifies and flagged.

## Completion notes

- Both parts landed: A in #520, B in this PR. Acceptance:
  - `cli/` holds the binary and what it needs, and no platform assets;
  - `platform/` has no OCaml;
  - the workflow `paths:` guard is in CI (part A);
  - no live reference to either old path remains.
- **Demo/example:** not applicable; this is repository layout, with no change to what an app author writes.
- **Language parity (DEC-022):** no application-facing impact.
