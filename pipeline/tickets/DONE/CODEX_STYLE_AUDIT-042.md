---
id: CODEX_STYLE_AUDIT-042
type: refactor
severity: medium
source: style audit
---

Make `Sun_process` command execution prefer argv over raw shell strings.

**Depends on:** none.

branch: CODEX_STYLE_AUDIT-042/sun-process-argv
worktree: /home/lbendtly/Code/sun-CODEX-042

**Problem:** `tools/sun_process/lib/sun_process.ml:9-25` exposes `run` and
`lines`/`output` APIs that take shell command strings. `run_argv` exists, but it
still quotes into a shell command instead of using an argv-spawn primitive.

**Goal:** Make shell interpretation explicit and make argv execution the safe
default.

**Acceptance criteria:**

- Introduce an argv-native execution path.
- Rename or mark shell-string helpers so call sites make shell use explicit.
- Update high-risk call sites that already have argv lists.

## Review — automated checks passed
Implementation satisfies CODEX_STYLE_AUDIT-042: Sun_process.run_argv now uses Unix.create_process directly, shell-string helpers are explicitly named run_shell/lines_shell/output_shell/run_shell_rc/run_shell_ok, existing intentional shell call sites were updated, an argv-native kubectl capture replaces a shell/temp-file path, and focused process/sundev tests plus CLI build passed. No baseline changes accepted.
