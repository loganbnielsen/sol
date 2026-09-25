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
