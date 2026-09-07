---
id: FEAT-032
type: feature
severity: high
source: user request, 2026-09-06 — full sun -> sol rename, following the docs-only rebrand in PR #136
---

**Depends on:** None.

Rename the project from `sun` to `sol` across code, CLI, config conventions, and build/release tooling. The GitHub repo itself has already been renamed (`loganbnielsen/sun` -> `loganbnielsen/sol`) and the local `origin` remote updated to match. This ticket is the remaining code/config/docs half of that rename.

## Goal

Nothing user-facing or internal should still say "sun" when this ticket is done, except: historical/dated records (past tickets in `project/tickets/DONE/`, `project/audits/`, `project/dogfood/`, `docs/audits/`, root-level `*-audit.md` investigation docs, and `docs/planning/WORK_SUMMARY.md`'s existing dated entries) — those describe what was true at the time and should not be rewritten. Add one new `WORK_SUMMARY.md` entry documenting this rename instead of rewriting history.

## Scope (surveyed 2026-09-06)

**Directories to rename** (`git mv`, preserving history):
- `cli/sun` -> `cli/sol`
- `framework/sun-svc` -> `framework/sol-svc`
- `framework/sun-worker` -> `framework/sol-worker`
- `framework/sun-fn` -> `framework/sol-fn`
- `framework/sun-obs` -> `framework/sol-obs`
- `framework/sun-env` -> `framework/sol-env`
- `tools/sundev` -> `tools/soldev`
- `tools/sun_process` -> `tools/sol_process`
- `examples/pluto/sun/` (target-file directory, e.g. `sun/prod/aws/us-east-1.yml`) -> `examples/pluto/sol/`

**OCaml module/file renames** (116 files reference `Sun_*` identifiers as of the survey):
- `Sun_cli_*` -> `Sol_cli_*` (all of `cli/sun/lib/sun_cli_*.ml{,i}`)
- `Sun_obs` -> `Sol_obs` (`framework/sun-obs/lib/sun_obs.ml{,i}`)
- `Sun_env` -> `Sol_env` (`framework/sun-env/lib/`)
- `Sun_process` -> `Sol_process` (`tools/sun_process/lib/`)
- `Sun_hosted` deployment-mode variant constructor (in `sun_cli_deployment_plan.ml{,i}`) -> `Sol_hosted`
- Note: `sun-svc`/`sun-worker`/`sun-fn`'s own public modules (`Service`, `Route`, `Response`, `Worker`, `FN`, `Notification`, etc.) are **not** `Sun_`-prefixed already — only their directory names change, not their module names.

**Dune library names and dependents:**
- Rename the `(name sun_cli)`/`sun_obs`/`sun_env`/`sun_process` library declarations to `sol_cli`/`sol_obs`/`sol_env`/`sol_process`.
- Update every consuming `(libraries ...)` stanza: `framework/sun-worker/{lib,test}/dune`, `framework/sun-obs/{lib,test}/dune`, `framework/sun-svc/{lib,test}/dune`, `framework/sun-fn/lib/dune`, `tools/sun_process/test/dune`, `tools/sundev/lib/dune`, `cli/sun/{lib,bin,test}/dune`, `examples/venus/bin/dune`, `examples/venus/app/comms/notify_worker/bin/dune`, `examples/venus/app/logistics/fulfillment_worker/bin/dune`, `examples/pluto/app/comms/notify_worker/bin/dune`, `examples/pluto/app/payments/charge_svc/bin/dune`, `examples/local-demo/{bin,test}/dune`.
- `sun.opam` -> `sol.opam`, update its `synopsis`/`name` fields (dune-project's `(name sun)` -> `(name sol)` generates this — check `dune-project` at repo root).

**Config/env naming Sol's CLI reads from disk:**
- `sun.toml` -> `sol.toml` (per-service overrides file)
- `sun.yml` -> `sol.yml` (workspace-level config)
- The `sun/<env>/<provider>/<region>.yml` target-file directory convention (`Filename.concat "sun"` in `cli/sun/lib/sun_cli_config.ml:568`) -> `sol/<env>/<provider>/<region>.yml`
- `SUN_HOME` env var -> `SOL_HOME`
- Scaffold templates (`sun_cli_scaffold_templates.ml`) must emit the new names into every newly generated workspace — including the generated CI workflow filename (`sun-ci.yml` -> `sol-ci.yml`) and its content.
- Update the bundled example workspaces (`examples/pluto/`, `examples/venus/`) to use the new file/directory names for real, not just in docs.

**CLI binary naming** (the dune executable target itself is unaffected — it's always `main.exe`, manually symlinked; see `.claude/CLAUDE.md`'s Build section):
- Everywhere the install/build instructions symlink `main.exe` to a name on `$PATH`, rename that target from `sun`/`sundev` to `sol`/`soldev`.
- `.github/workflows/release.yml`: bundle name (`sun-${VERSION}-linux-x86_64` -> `sol-...`), binary filename inside the bundle (`bin/sun` -> `bin/sol`), standalone binary asset (`sun-linux-x86_64` -> `sol-linux-x86_64`), smoke-test invocation (`${BUNDLE}/bin/sun --help` -> `.../bin/sol --help`), and the `dune build cli/sun/bin/main.exe` path (-> `cli/sol/bin/main.exe` once the directory move lands).
- `.github/workflows/ci.yml` — check for any `cli/sun`/`sun`-named references.

**Docs to update in full** (living/reference docs — rename thoroughly, including every `sun <command>` example):
- `README.md` (already Sol-branded in prose from PR #136; now update every command example, the install URL — repo is `loganbnielsen/sol` now — and remove the "rebrand in progress" callout since this ticket finishes it)
- `docs/guides/TUTORIAL.md`
- `docs/planning/ROADMAP.md`, `docs/planning/LIVE_DEV_DEPLOY_ROADMAP.md`, `docs/planning/OPAM_FOUNDATION_TRACKER.md`
- `docs/architecture/*.md` (`PRODUCT_ARCHITECTURE.md`, `devops-pipeline.md`, `observability-design.md`, `contributing-map.md`, `adr/*`)
- `docs/deployment/*.md` (`escape-hatches.md`, `observability-backends.md`, `self-hosted-substrate-contract.md`)
- `docs/hosted/*` (check if living or historical)
- `.claude/CLAUDE.md` (this repo's own Claude context file — update package name, binary name, repo layout, env vars)
- `.github/CODEOWNERS` if it references paths like `cli/sun/`

**Explicitly out of scope / leave as historical record:**
- `project/tickets/DONE/*`, `project/tickets/*` generally (ticket bodies are a point-in-time record; do not rewrite past ticket prose — only the ticket *system* itself, e.g. `sundev` binary name references in **current** skill docs under `.claude/skills/` and `.claude/CLAUDE.md`, needs updating)
- `project/audits/*`, `project/dogfood/*`, `docs/audits/*` (dated reports)
- Root-level `aws-audit.md`, `obs-audit.md`, `storage-audit.md`, `obs-extraction-plan.md` (point-in-time investigation docs)
- `docs/planning/WORK_SUMMARY.md`'s existing entries — add one new dated entry for this rename instead of editing history
- Sibling `*-eio` repos (`aws-eio`, `kafka-eio`, `obs-eio`, `pg-eio`, etc.) — separate repos, not touched by this ticket
- `~/Code/CLAUDE.md` (one level above this repo, shared across all `~/Code/*` repos, not itself part of this git repo)
- The local clone's own directory name (`/home/lbendtly/Code/sun` on disk) — a local filesystem detail, not a git-tracked change

## Remediation

1. Rename directories with `git mv` (preserves blame/history).
2. Rename OCaml module files and update every identifier reference (module names, dune library names, dune `(libraries ...)` stanzas) until `dune build` is clean.
3. Update the config/env conventions the CLI reads (`sol.toml`, `sol.yml`, `SOL_HOME`, the `sol/<env>/...` target-file directory) in code, scaffold templates, and the two bundled example workspaces' actual files.
4. Update `.github/workflows/release.yml` and `ci.yml`, and `sun.opam`/`dune-project`'s package name.
5. Update the living docs listed above. Leave historical/dated records untouched; add one new `WORK_SUMMARY.md` entry for the rename.
6. Run the full test suite (unit, kafka, e2e — `platform/local/scripts/run_tests.sh` or `sundev`'s equivalent once renamed) and confirm green.
7. Because of the sheer file count, review in at least two passes: one focused purely on "does it build and pass tests," a second focused on "did any doc/example/scaffold-template drift from the renamed code" (a scaffold template that still emits `Sun_cli`-shaped code, or a doc that still shows a `sun` command, is the likely failure mode here).

## Acceptance criteria

- `dune build` and the full test suite (unit + kafka + e2e) pass.
- `grep -rI 'Sun_\|sun\.toml\|sun\.yml\|SUN_HOME' --include='*.ml' --include='*.mli' --include=dune .` (excluding the explicitly-historical paths above) returns nothing.
- A freshly scaffolded workspace (`sol new workspace <name>` after rename) generates a workspace with no `Sun_`/`sun.toml`/`sun.yml`/`sun-ci.yml` references anywhere in it.
- README's Quickstart runs end-to-end with the renamed binary/commands.
