---
id: REFAC-003
type: refactor
severity: high
source: codebase simplification review 2026-06-13
branch: REFAC-003/split-scaffold-modules
worktree: ../sun-REFAC-003-split-scaffold-modules
---

Split `sun_cli_cmd_new.ml` (1,167 lines) into per-primitive scaffold modules to make the scaffolder navigable

**Depends on:** None.

**Description:**

`cli/sun/lib/sun_cli_cmd_new.ml` is 1,167 lines and handles scaffolding for all four primitive types (`-svc`, `-worker`, `-fn`, event contracts), plus workspace creation, plus shared helpers (manifest generation, dune/opam file rendering, file-tree assembly). It is the single hardest file to navigate in the codebase — finding where a specific scaffold template lives requires scanning hundreds of lines.

The file has natural internal seams: each primitive type is largely self-contained (its own template strings, its own `generate_*` function, its own file list). Shared infrastructure (file-write helpers, TOML parsing, manifest stubs) is separable.

**Remediation:**

Split into the following modules under `cli/sun/lib/`:

| New module | Content |
|---|---|
| `Sun_cli_scaffold_svc.ml` | `-svc` template strings + `generate_svc` |
| `Sun_cli_scaffold_worker.ml` | `-worker` template strings + `generate_worker` |
| `Sun_cli_scaffold_fn.ml` | `-fn` template strings + `generate_fn` |
| `Sun_cli_scaffold_event.ml` | event contract template strings + `generate_event` |
| `Sun_cli_scaffold_workspace.ml` | workspace init + top-level `run` dispatch |
| `Sun_cli_scaffold_util.ml` | shared: `write_file`, `ensure_dir`, TOML stubs, manifest helpers |

`sun_cli_cmd_new.ml` can either be deleted (with the entry point moved to `sun_cli_scaffold_workspace.ml`) or reduced to a thin dispatcher that calls into the new modules.

Keep the public interface of `Sun_cli_cmd_new` (specifically whatever `cmd_new.ml` in `bin/` calls) stable across the split so the `bin/` layer needs no changes, or update `bin/main.ml` in the same commit.

**Acceptance criteria:**

- No single module in `cli/sun/lib/` exceeds ~300 lines after the split.
- `dune build` and `dune test cli/sun/` pass.
- `sun new svc`, `sun new worker`, `sun new fn`, `sun new event`, and `sun new workspace` all produce the same output as before (verify with `test_scaffold.ml`).

## Review — automated checks passed
sun_cli_cmd_new.ml split into 7 focused modules; build and tests pass, all acceptance criteria met
