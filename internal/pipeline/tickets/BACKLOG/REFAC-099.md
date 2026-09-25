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
- Update every consumer of both paths in the same change: SOL_HOME resolution (`Sol_cli_cmd_new.infer_sol_home` and every `Filename.concat sol_home "cli/platform/…"`), Terraform `local.platform_components_dir`, `internal/ci/`, `.github/workflows/`, `internal/ci/classify-changes.sh`, the hooks, `AGENTS.md`, `CONTRIBUTING.md`, and docs. That includes the binary path `_build/default/cli/sol/bin/main.exe`.

This is the first move so that the later platform tickets change each path only once.

## Acceptance criteria

- `cli/` contains only OCaml and dune files. `platform/` contains no OCaml.
- `rg -n --hidden -g '!.git' '<old path>'` returns nothing outside `internal/pipeline/` and dated historical records. Put the exact commands and their empty output in the completion notes.
- `dune build`, `dune test cli/` and `internal/ci/check_ocamlformat.sh --all` pass, and CI is green.

## Completion notes (required)

- Demo/example: not applicable (repository layout; no change to what an app author writes) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`.
