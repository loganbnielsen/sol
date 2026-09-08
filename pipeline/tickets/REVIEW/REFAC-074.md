---
id: REFAC-074
type: refactor
severity: medium
source: architecture discussion with user, 2026-09-08
branch: REFAC-074/platform-under-cli
worktree: ../sol-REFAC-074-platform-under-cli
pr: https://github.com/loganbnielsen/sol/pull/163
---

**Depends on:** REFAC-073.

Fold `platform/` under `cli/`

**Sequencing note:** work in sequence, not concurrently — see REFAC-071 for the full sequencing note and the four-part decision this belongs to. This is the largest and riskiest of the four moves — do it last, with extra care.

## Decision

Neither `platform/local/` (scripts + k8s manifests that `sol dev up` shells out to) nor `platform/infra/` (Terraform modules + CI/CD reference workflows that `sol cloud`/`sol deploy` render from) is code an app author's OCaml binary links against — both are operational substrate the CLI itself consumes to do its job. Sitting as a sibling to `framework/` at the top level blurs that distinction. Moving it under `cli/` makes explicit: this is deployment machinery belonging to the product, not a library.

## Remediation

- Land on a concrete target shape before moving anything — likely `cli/platform/local/` and `cli/platform/infra/` (or `cli/sol/platform/` if it should live inside the `sol` package directory specifically; check whether anything outside `cli/sol/` references `platform/` before deciding). Pick whichever keeps `cli/sol/bin/`'s existing relative-path assumptions (e.g. `Sys.command` calls shelling out to `platform/local/scripts/*.sh`) simplest to fix.
- `git mv platform <target>`.
- Update every `Sys.command`/`Filename.concat`/hardcoded path in `cli/sol/lib/` and `cli/sol/bin/` that references `platform/local/scripts/*`, `platform/infra/*`, or `platform/local/k8s/*`.
- Update `platform/infra/ci/github-actions-*.yml` reference workflows' own internal paths if they reference sibling `platform/` paths.
- Update `docs/deployment/*.md`, `docs/guides/TUTORIAL.md`, `README.md`, `.claude/CLAUDE.md`'s repo layout section, and `docs/planning/ROADMAP.md`/`WORK_SUMMARY.md`.
- Update the `ensure-*.sh` scripts and any script-to-script relative references inside `platform/local/scripts/`.
- Grep the whole repo for `platform/local`, `platform/infra`, and bare `platform/` to catch anything missed — this is the widest-blast-radius move of the four, expect many hits across CLI source, docs, and CI.
- Run the full local test suite before submitting. Additionally, manually exercise at least one real `sol dev up` cycle (or the closest available integration test) to confirm the CLI's shell-out paths still resolve correctly post-move — a broken path here fails silently at runtime, not at build time.
