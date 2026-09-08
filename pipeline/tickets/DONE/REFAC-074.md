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

## Review — real CI confirmed green (2026-09-08)

Chose `cli/platform/` (sibling to `cli/sol/`, not nested inside it) since `devtools/soldev/lib/soldev_merge.ml` also shells out to it — nesting under `cli/sol/` would misrepresent it as private to that binary. A real REPO_ROOT path-depth bug in `run_tests.sh`/`install-hooks.sh`/`perf.sh` was found and fixed only by actually running the suite post-move, not by `dune build` alone (shell-script string paths aren't compiler-checked). Review confirmed the fix is complete (no other script under the moved tree needed it), independently re-ran the full suite (pass), re-verified shell-out `Filename.concat` sites resolve to real files, grepped for missed references (only 2 hits, both in root-level `*-audit.md` files already handled separately — since deleted), and confirmed no stray `cli/sol/platform/` references. Branch was rebased against origin/main after REFAC-073's merge (commit 5ba4b342). PR #163's actual GitHub Actions run (34282913259) fully green: `test` passed, all 4 dockerfile-smokes passed, `golden-path-smoke` passed (14m46s). Promoting on confirmed real-CI green — this is the fourth and final ticket of the reorg.

## Merge false-positive, manually resolved (2026-09-08)

`soldev pipeline merge` squash-merged PR #163 correctly, then its own post-merge test/baseline step ran `./platform/local/scripts/run_tests.sh` using the currently-executing (stale, pre-rename) `soldev` binary — that path no longer existed after this exact merge moved it to `cli/platform/local/scripts/run_tests.sh`, so the invocation failed and triggered soldev's automatic safety revert + `BLOCKED_BY_PERFORMANCE` move. This was a false positive (the same stale-binary class of issue seen after REFAC-072/073's merges, just this time tripping the revert safety net instead of leaving a ticket-file mess) — real GitHub CI on this exact commit was already confirmed green minutes earlier. Caught before the revert was ever pushed (it and the `BLOCKED_BY_PERFORMANCE` move were local-only); discarded both via `git reset --hard origin/main`, rebuilt `soldev` against the now-current `cli/platform/` source, and re-ran the full suite manually with the correct binary — all pass, confirming the merge itself was sound. Completed the remaining lifecycle steps (baseline commit, this move to DONE) by hand.
