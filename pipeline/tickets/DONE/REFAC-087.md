---
id: REFAC-087
type: refactor
severity: low
source: split from REFAC-086, 2026-09-11 — the naming half of the local/target work
---

**Depends on:** None.

**Premise checked 2026-09-12:** `cli/sol/bin/cmd_dev.ml` still existed and `devtools/ci/check_platform_component_drift.sh` still hardcoded its path, so the rename was genuinely outstanding.

**Related:** REFAC-086 (which landed the alias removal and the destination guard), REFAC-083 (which renamed the command to `local`), DEC-016, DEC-020, **REFAC-088** (the capability-core half, split out on 2026-09-12 because it needs FEAT-063's destination abstraction).

Name the file that implements the `local` group for what it contains.

## Work

Rename `cmd_dev.ml` → `cmd_local.ml`. The file implements the `local` group (`Cmd.group (Cmd.info "local" ~doc:"Manage the local cluster (k3d) and its substrate")`) and has not been named for what it contains since REFAC-083 renamed the command. Cosmetic on its own, but naming carries weight in a codebase actively keeping `dev`, `local`, `target`, `environment` and `destination` distinct.

References that must move with it, because a stale one is not cosmetic:

- `cli/sol/bin/main.ml` (`Cmd_dev.cmd` → `Cmd_local.cmd`) and the module list in `cli/sol/bin/dune`.
- `devtools/ci/check_platform_component_drift.sh`, which hardcodes the path as `cmd_dev="$repo_root/cli/sol/bin/cmd_dev.ml"`. Left stale, its `grep` reads a missing file, the `if` goes false and the guardrail passes silently — so this reference is load-bearing.
- Comments and current-state docs that name the file (`cli/sol/lib/sol_cli_status.ml`, `cli/sol/test/test_tool_adapters.ml`, `cli/platform/infra/base/main.tf`, the docs under `docs/`).

**Deliberately not updated:** historical records under `pipeline/audits/` and `pipeline/dogfood/` describe what was true when they were written; rewriting them would falsify the record rather than fix a reference.

## Acceptance criteria

- The file implementing the `local` group is named `cmd_local.ml`, and `main.ml`/`dune` reference `Cmd_local`.
- The drift guardrail points at the new path.
- No reference to the old module name remains in code, build files, or docs describing current state.

## Completion notes

Landed 2026-09-12.

- `cli/sol/bin/cmd_dev.ml` → `cli/sol/bin/cmd_local.ml` (`git mv`, so history
  follows), with `cli/sol/bin/dune` and `main.ml` (`Cmd_dev.cmd` →
  `Cmd_local.cmd`) updated.
- `devtools/ci/check_platform_component_drift.sh`'s `cmd_local` variable and its
  keys/messages now point at the new path. This was the load-bearing one: with
  the old path the `grep` reads a missing file, the `if` goes false, and the
  guardrail passes silently — verified it still runs and reports against
  `cmd_local.ml`.
- Comments and current-state docs updated: `sol_cli_status.ml`,
  `test_tool_adapters.ml`, `cli/platform/infra/base/main.tf`, ADR 0001,
  `docs/architecture/devops-pipeline.md`,
  `docs/deployment/observability-backends.md`, `docs/planning/ROADMAP.md`.
- **Left as historical record:** `pipeline/audits/*`, `pipeline/dogfood/*` and
  `docs/planning/WORK_SUMMARY.md`, which state what was true when written;
  rewriting them would falsify the record rather than fix a reference. Verified
  the only remaining `cmd_dev` mentions are those plus ticket prose.

Verified: `dune build`, the drift guardrail, and the full `cli/sol/test` suite
all pass. Demo/example coverage: no CLI surface change — `sol local` and its
subcommands are untouched; only the module file's name moved.
