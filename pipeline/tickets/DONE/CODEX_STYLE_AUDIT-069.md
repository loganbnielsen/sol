---
id: CODEX_STYLE_AUDIT-069
type: refactor
severity: high
source: docs/audits/STYLE_AUDIT.md
branch: CODEX_STYLE_AUDIT-069/typed-rollback
worktree: ../sun-CODEX_STYLE_AUDIT-069-typed-rollback
---

Unify rollback intent with deployment plan history.

**Depends on:** CODEX_STYLE_AUDIT-068.

**Problem:** `cli/sun/bin/cmd_rollback.ml` shells out to Kubernetes rollout
commands based on discovered services and current cluster resources. The command
does not clearly connect rollback behavior to the deployment plan or recorded
state, which makes rollback semantics hard for CI/CD contributors to trust.

**Goal:** Make rollback a typed operation over known deployment state and
workload kind.

**Acceptance criteria:**

- Introduce rollback intent types for standard Deployment and Argo Rollout
  workloads.
- Derive rollback targets from the deployment plan/state where possible.
- Keep raw kubectl commands in the typed kubectl adapter.
- Add tests for service, worker, function/no-op, and Argo Rollouts plugin-missing
  behavior.

## Review — automated checks passed
Build clean, all tests pass, all kubectl argo commands routed through Sun_cli_kubectl adapter, rollback_target type correct with all required variants, test coverage complete, no wrapped true, project/tickets untouched.
