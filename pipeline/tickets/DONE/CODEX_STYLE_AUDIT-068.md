---
id: CODEX_STYLE_AUDIT-068
type: refactor
severity: high
source: docs/audits/STYLE_AUDIT.md
branch: CODEX_STYLE_AUDIT-068/explicit-deployment-state
worktree: ../sun-CODEX_STYLE_AUDIT-068-explicit-deployment-state
---

Make deployment state updates explicit and failure-aware.

**Depends on:** CODEX_STYLE_AUDIT-061.

**Problem:** Deployment state is updated in command flows such as
`cmd_up.ml:216-219` and helper modules like `Sun_cli_deployment_state`, while
apply/build/push/rollout failures happen elsewhere. It is hard to verify that
state only records successful mutations and that dry-run or partial failure paths
never record misleading state.

**Goal:** Treat state updates as a typed final phase of successful execution.

**Acceptance criteria:**

- Add an execution result type that distinguishes planned, applied, partially
  applied, failed, and dry-run outcomes.
- Move deployed-state writes behind a function that requires a successful
  execution result.
- Add tests for dry-run, failed build/push/apply, and successful apply.

## Review — automated checks passed
execution_outcome type with Applied/Emitted/Dry_run/Failed variants added; record_outcome is a no-op for Dry_run/Emitted/Failed; cmd_deploy.ml and cmd_up.ml both migrated from save_deployed_groups to record_outcome; tests cover dry-run, failed, emitted, applied, and removed-group edge cases; build clean; no wrapped true; project/tickets/ untouched
