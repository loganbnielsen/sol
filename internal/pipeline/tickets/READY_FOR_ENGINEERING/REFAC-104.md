---
id: REFAC-104
type: refactor
severity: low
title: Split cli/lib into per-domain dune libraries along its dependency graph
source: internal/pipeline/audits/2026-09-25_organization_proposal.md, rule 6
---

**Depends on:** REFAC-099.

**Premise verified (2026-09-25):** `ls cli/sol/lib | wc -l` → 157 files in one directory, grouped only by prefix (`sol_cli_deployment_*` ×15, `sol_cli_release_*` ×10, `sol_cli_terraform_*` ×7, …).

## Remediation

**The deliverable is the graph and a decision for each domain.** Moving files is secondary.

1. Derive the module dependency graph (`dune describe` or `ocamldep`) and propose domains that minimize cross-domain edges. A starting sketch from prefixes is `workspace`, `local`, `cloud`, `deploy`, `kubernetes`, `observability` and `secrets`, but the graph decides.
2. For each domain, record **library** (it has no cycle with the rest) or **stays in the top-level library** (and name the cycle that keeps it there).
3. Each library domain gets its own directory and `dune` stanza, still `(wrapped false)`. No module is renamed, but a module can only reference another domain if its `dune` lists that domain, so the boundary is enforced at build time. The top-level library keeps an explicit `(modules …)` list for the remainder, as `cli/sol/lib/dune` does today.
4. **Mechanism:** use `(include_subdirs no)`, the default, with a `dune` per domain directory. Don't use `(include_subdirs unqualified)`: dune treats every subdirectory of such a tree as part of the enclosing library, so nested library stanzas can't coexist with it. Use it only if the graph's answer turns out to be "folders everywhere", and say so if it does.

## Acceptance criteria

- No module name changes: `git diff --stat` shows renames only, apart from `dune` files.
- The completion notes include the graph, the decision for each domain, and, for each domain left in the top-level library, the cycle that keeps it there.
- A mutation check: adding a reference from one library domain to another that its `dune` doesn't list fails the build.
- `dune build`, `dune test cli/` and the format check pass.

## Completion notes (required)

- Demo/example: not applicable (repository layout; no change to what an app author writes) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`.
