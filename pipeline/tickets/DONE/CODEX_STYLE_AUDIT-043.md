---
id: CODEX_STYLE_AUDIT-043
type: refactor
severity: low
source: style audit
---

Replace process `exit_code : int` with a typed process status.

**Depends on:** CODEX_STYLE_AUDIT-042.

branch: CODEX_STYLE_AUDIT-043/process-status-type
worktree: /home/lbendtly/Code/sun-CODEX-043

**Problem:** `tools/sun_process/lib/sun_process.ml:1-5` stores only
`exit_code : int`, flattening normal exits and signal deaths into integers via
`exit_of_status`.

**Goal:** Preserve process termination semantics in the type.

**Acceptance criteria:**

- Add a status variant for exited, signaled, and stopped.
- Provide a helper for shell-compatible numeric exit code where needed.
- Update tests and callers that inspect `.exit_code`.

## Review — automated checks passed
Implementation satisfies CODEX_STYLE_AUDIT-043: Sun_process.result now exposes typed Exited/Signaled/Stopped status, shell-compatible exit conversion is available through status_to_exit_code/exit_code, success checks use Sun_process.succeeded, direct .exit_code callers were updated, and focused process tests plus CLI build passed. No baseline changes accepted.
