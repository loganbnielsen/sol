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

## Disposition (2026-10-03) — decision required

Smallest decision: remove the last process-wide `chdir` (resolve every workspace-relative path against an explicit root, ~119 sites) or keep the single-entry-point convention from REFAC-108. Consequence: removal is a wide, behavior-preserving refactor with real regression surface; keeping it closes the ticket.

Surfaced to the operator as a category-5 decision; not deferred. Moves to
`READY_FOR_ENGINEERING/` once the decision is recorded. See
`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`.


## Decision (2026-10-03) — keep the single-entry-point convention

Decided by this pass: **No.** Behaviour is already correct and the `chdir`
happens in exactly one place (`Sol_cli_workspace.enter_or_exit`), so the
process-wide cwd dependency stays; removing it across ~119 sites is regression
surface without a functional driver. REFAC-108's single-entry-point convention
stands. Promoted to `READY_FOR_ENGINEERING` only so the transition guard can
close it as "no change".


## Closed (2026-10-03) — decided no change

Keep the single-entry-point convention from REFAC-108: the one `chdir` in
`Sol_cli_workspace.enter_or_exit` stays. Removing it across ~119 sites is
regression surface without a functional driver. Decision recorded in the
adjudication ledger.
