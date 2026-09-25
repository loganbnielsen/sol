---
id: INFRA-075
type: bug
severity: medium
title: Tests write runs into the real Sol home and prune real qualification evidence
source: internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md
---

**Depends on:** None.

**Related:** FND-0055, HARDEN-004

**Plan:** `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`, § S1.a. The plan is authoritative for scope; this ticket carries the dependency and the acceptance criteria.

**Premise verified 2026-09-24:** `ls ~/.local/share/sol/runs/` held exactly 21 `cloud-destroy-20260925T005743Z-*` runs, all started within one minute. `Sol_cli_run_log.create` keeps 20 runs across every command prefix (`cli/sol/lib/sol_cli_run_log.ml:99`), so that burst pruned every earlier run, including the Attempt 6 and Attempt 7 run directories.

## Problem

Something that runs as a test writes into the user's real Sol home. With the shared keep-20 policy, every such run deletes real evidence. The lifecycle simplification program compares before/after evidence, so this lands first.

## Remediation

Identify the writer (`Sol_cli_run_log.create` callers reachable from tests, and scripts that leave `SOL_HOME` unset; `internal/ci/test_cloud_lifecycle_offline.sh` already exports it). Isolate every test's `SOL_HOME` hermetically.

## Acceptance criteria

- The writer is named in the completion notes, with the command that found it.
- An executable guard fails a test run that would write under the real user Sol home.
- Running the full offline suites leaves `~/.local/share/sol/runs/` byte-for-byte unchanged (show the before/after listing).

## Completion notes (required)

- Demo/example: not applicable (cloud lifecycle internals) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`, and any finding/decision whose status this changes.

## Completion notes (2026-09-24)

**The writer:** `internal/ci/test_cloud_lifecycle_offline.sh`, run by `cli/sol/test`'s `runtest`
alias. It drives the real `sol cloud apply|destroy` (22 invocations) and exported only `SOL_HOME`,
but Sol's run logs and state live under `$XDG_DATA_HOME/sol`, falling back to
`~/.local/share/sol` (`cli/sol/lib/sol_cli_state.ml:1-8`), which `SOL_HOME` does not affect. Found
with `rg -n 'XDG_DATA_HOME|export HOME|HOME=' internal/ci/*.sh cli/sol/test/` (the only hit was the
harness's `export SOL_HOME`) and confirmed from the polluting runs' contents:
`~/.local/share/sol/runs/cloud-destroy-20260925T005743Z-1663731/declared-universe-show.log` lists the
harness's fixture addresses. The other `cli/sol/test` rules that run the binary (`plan`, `check`,
`target show`, `deploy`) inherited the same environment.

**The fix:**
- `cli/sol/test/dune` gains an `(env)` stanza setting `XDG_DATA_HOME` for every action in the
  directory (relative, so it resolves inside the build or temp directory the action runs in).
- The harness exports an absolute `XDG_DATA_HOME="$tmp/xdg-data"`.

**Executable guards:**
- A `runtest` rule fails if `XDG_DATA_HOME` is unset for `cli/sol/test` actions or points at the
  real data home.
- An INFRA-075 canary at the end of the harness fails if no `cloud-*` run landed in the isolated
  home, i.e. if the runs went anywhere else. Positive control: a first version also required a
  `cloud-apply-*` run and fired, because Sol's keep-20 pruning removes the early apply runs inside
  the isolated home too; the canary now requires any `cloud-*` run and says why.

**Before/after (real data home):** `ls ~/.local/share/sol/runs | sort` was captured before running
`dune test cli/sol/test/` and diffed after: identical (21 entries) — previously every full run
replaced them.

**Tests run:** `dune build` then `dune test cli/sol/test/`: all pass (exit 0), including after
merging `main` (SEC-010). An earlier local run that skipped the full `dune build` failed
`test_scaffold` `existing_files` 6 and 7 with *Library "sol-obs" not found*. That is a build-order
artifact of testing without building the framework first: it failed identically with and without
`XDG_DATA_HOME`, and it passes after a full build. (An earlier version of this note blamed the opam
switch; that was wrong.)

- Demo/example: not applicable (test infrastructure only).
- Language parity (DEC-022): no application-facing impact.
- Lost evidence is not recoverable: the Attempt 6/7 run directories were already pruned before this
  fix; the frozen bundles in `~/sol-attempt6-evidence/` and `~/sol-attempt7-evidence/` are the record.
