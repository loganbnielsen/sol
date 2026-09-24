---
id: REFAC-091
type: refactor
severity: high
source: internal/pipeline/audits/2026-09-23_correctness_audit.md
---

Port the cloud install/destroy lifecycle to a result-returning `execute ~deps`, exiting only at the command edge

**Depends on:** None.

**Finding:** FND-0047 (`internal/pipeline/audits/findings/`).

**Premise verified 2026-09-23** against `origin/main @ f3e9480b` while filing (see the finding).

## Problem

`require_terraform_success`/`lifecycle_error` `exit` from inside helpers, so finalizers do not run and cleanup is hand-threaded through `on_error` (FND-0047 is a branch that forgot). The destroy sequence cannot be tested or replayed offline.

## Remediation

Follow `cmd_rollback.ml`: a `Sol_cli_cloud_destroy.execute ~deps` (and install equivalent) returning a typed outcome, terraform/gcloud/aws injected as deps, cleanup bracketed with `Fun.protect`, one place mapping outcome → exit code. Take one state inventory at the start (shared with INFRA-068/069/071/072).

## Acceptance criteria

- Offline test replays the Attempt-6 state shape through `execute` with fakes.
- No `exit` remains below the command edge in the destroy path (grep check).
- Demo/example: not applicable (internal refactor) — state in completion notes.
