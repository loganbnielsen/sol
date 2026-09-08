---
id: CODEX_STYLE_AUDIT-063
type: refactor
severity: high
source: docs/audits/STYLE_AUDIT.md
branch: CODEX_STYLE_AUDIT-063/typed-process-api
worktree: ../sun-CODEX_STYLE_AUDIT-063-typed-process-api
---

Centralize external command execution behind a typed process API.

**Depends on:** none.

**Problem:** Shell/process execution is scattered across `Sun_cli_shell`,
`Sun_process`, `Sun_cli_manifest`, `Sun_cli_secret`, `cmd_up.ml`,
`cmd_cloud_deploy.ml`, `cmd_logs.ml`, `cmd_status.ml`, `cmd_cloud_tf.ml`, and
`cmd_dev.ml`. Contributors must inspect every call to understand quoting,
stdout/stderr capture, failure handling, and dry-run behavior.

**Goal:** Make external process execution consistent and auditable.

**Acceptance criteria:**

- Create one process abstraction used by CLI code, with argv-native execution,
  optional cwd/env, timeout, echo/redaction, stdout/stderr capture, and typed
  status.
- Mark shell-string execution as explicit and exceptional.
- Convert high-risk `kubectl`, `docker`, `helm`, `terraform`, and `git` paths to
  argv execution.
- Add tests for quoting, non-zero exit status, captured stderr, and redacted
  logging.

## Review — automated checks passed
Sun_cli_process module correctly introduced with argv-native run/run_ok/run_shell, redaction, typed errors; all kubectl/docker/helm/terraform/git callers converted; tests pass; no new Sys.command calls; no project/tickets/ changes; wrapped false preserved
