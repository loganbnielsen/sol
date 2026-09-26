---
id: REFAC-110
type: refactor
severity: low
title: Remove the last chdir -- resolve every workspace-relative path against an explicit root
source: REFAC-108 part B (2026-09-26)
---

**Depends on:** None.

## Context

REFAC-108 routed every command through one validated entry point, `Sol_cli_workspace.enter_or_exit`, which still `chdir`s to the workspace root once. Removing that last `chdir` means every consumer of a workspace-relative path takes the root explicitly: unit directories (`app/<domain>/<unit>`), Docker build contexts, `sol.toml` reads, migrations, schema discovery.

`rg -n '\.dir\b|~context:|Sol_cli_toml.load|sol\.toml|Dockerfile"' cli/lib cli/bin --glob '*.ml'` → 119 sites in 20 files (2026-09-26).

## Decision Required

Is removing the process-wide cwd dependency worth a change of this size and regression risk, given that behaviour is already correct and the `chdir` happens in exactly one place?

- **Yes:** keep unit paths workspace-relative as data and resolve them against the root only at I/O boundaries, via one `Sol_cli_workspace.path ~root rel` helper, then remove `enter`'s `chdir`.
- **No:** close this ticket; the single-entry-point convention from REFAC-108 stands.

## Acceptance criteria (if yes)

- `rg -n 'Sys.chdir' cli/lib cli/bin` returns nothing.
- `dune test cli/test/` and the golden-path smoke pass.
- **Demo/example:** not applicable (internal).
