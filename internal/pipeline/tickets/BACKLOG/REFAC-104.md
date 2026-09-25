---
id: REFAC-104
type: refactor
severity: low
title: Group cli/lib into domain subfolders from its dependency graph
source: internal/pipeline/audits/2026-09-25_organization_proposal.md, rule 6
---

**Depends on:** REFAC-099.

**Premise verified (2026-09-25):** `ls cli/sol/lib | wc -l` → 157 files in one directory, grouped only by prefix (`sol_cli_deployment_*` ×15, `sol_cli_release_*` ×10, `sol_cli_terraform_*` ×7, …).

## Remediation

1. Derive the module dependency graph (`dune describe` or `ocamldep`) and propose domain folders that minimize cross-folder edges. A starting sketch from prefixes is `workspace/`, `local/`, `cloud/`, `deploy/`, `kubernetes/`, `observability/` and `secrets/`, but the graph decides, and the chosen grouping goes in the completion notes.
2. Move the files under `(include_subdirs unqualified)`. The libraries are `(wrapped false)`, so no module is renamed and no call site changes.
3. If DEC-046 chose separate dune libraries (its open question 3), split them in a follow-up rather than here.

## Acceptance criteria

- No module name changes: `git diff --stat` shows renames only, apart from `dune` files.
- The completion notes include the cross-folder edge counts, so a later split into libraries can see where the seams are.
- `dune build`, `dune test cli/` and the format check pass.

## Completion notes (required)

- Demo/example: not applicable (repository layout; no change to what an app author writes) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`.
