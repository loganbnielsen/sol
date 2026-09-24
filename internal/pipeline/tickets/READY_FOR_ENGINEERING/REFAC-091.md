---
id: REFAC-091
type: refactor
severity: high
source: internal/pipeline/audits/2026-09-23_correctness_audit.md
---

Port the cloud install/destroy lifecycle to a result-returning `execute ~deps`, exiting only at the command edge

**Depends on:** None.

**Finding:** FND-0047, FND-0048, FND-0044 (point 2) (`internal/pipeline/audits/findings/`).

**Sequencing:** this is step 2 of the HARDEN-004 order in `internal/pipeline/audits/HARDEN-004-handoff.md` ("The order now"). Coordinate with the HARDEN-004 owner; land it as that step, not in parallel. The typed state inventory replaces outputs-based "substrate exists" (FND-0044 point 2) and identifies guarded resources by address (FND-0048, formerly INFRA-071).

**Premise verified 2026-09-23** against `origin/main @ f3e9480b` while filing (see the finding).

## Problem

`require_terraform_success`/`lifecycle_error` `exit` from inside helpers, so finalizers do not run and cleanup is hand-threaded through `on_error` (FND-0047 is a branch that forgot). The destroy sequence cannot be tested or replayed offline.

## Remediation

Follow `cmd_rollback.ml`: a `Sol_cli_cloud_destroy.execute ~deps` (and install equivalent) returning a typed outcome, terraform/gcloud/aws injected as deps, cleanup bracketed with `Fun.protect`, one place mapping outcome → exit code. Take one state inventory at the start (shared with INFRA-068/069/071/072).

## Acceptance criteria

- Guarded resources come from real addresses (root and child modules); an empty state (no `values`) is empty, not an error; a null `deletion_protection` does not raise (FND-0048 fixtures).
- A partial-outputs state is destroyable (FND-0044 point 2).
- Offline test replays the Attempt-6 state shape through `execute` with fakes.
- No `exit` remains below the command edge in the destroy path (grep check).
- Demo/example: not applicable (internal refactor) — state in completion notes.
