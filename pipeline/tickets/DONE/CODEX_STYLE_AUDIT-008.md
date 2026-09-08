---
id: CODEX_STYLE_AUDIT-008
type: refactor
severity: high
source: style audit
branch: CODEX_STYLE_AUDIT-008/typed-release-status
worktree: ../sun-CODEX-008
---

Replace registry status string updates with typed status transitions.

**Depends on:** none.

**Problem:** The in-memory registry defines `release_status`, but
`cli/sun/lib/sun_cli_registry.ml:106-116` accepts `status_str : string` and maps
unknown values to `Queued`. The persistent registry repeats raw status parsing at
`cli/sun/bin/cmd_cloud_registry.ml:115-130`.

**Goal:** Prevent invalid release and service statuses from compiling past the
database/JSON boundary.

**Acceptance criteria:**

- Change `update_release_status` to accept `release_status`.
- Add explicit parse functions returning `('status, string) result` for DB/JSON
  inputs instead of defaulting unknown strings.
- Use the same parser in `cmd_cloud_registry.ml` and any tests.
- Preserve `release_status_to_string` and `service_status_to_string` for output.

## Review — automated checks passed
All callers updated to typed release_status; release_status_of_string added; build clean; no project/tickets/ changes in branch.
