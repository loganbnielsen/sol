---
id: AUDIT-051
type: audit-finding
severity: medium
source: codebase review 2026-06-14
branch: AUDIT-051/structured-process-runner
worktree: /home/lbendtly/Code/sun-AUDIT-051-structured-process-runner
---

Replace ad hoc shell command helpers with a structured process runner

**Depends on:** None.

**Description:** The codebase has multiple command helpers that build shell strings, redirect to temp files, then read the temp file back. Examples include `cli/sun/lib/sun_cli_shell.ml` and `tools/sundev/lib/sundev_shell.ml`, which duplicate `read_file`, `run_cmd`, and `run_cmd_lines` patterns. Higher-level modules such as secret management, manifest apply, deploy, and pipeline operations then build their own command strings on top.

**Impact:** Shell execution behavior is spread across the codebase and remains hard to test. Capturing stdout/stderr through temp files loses exit-status detail, makes cleanup best-effort, and pushes quoting correctness onto every caller. The duplication also makes it harder to improve logging, timeouts, and error reporting consistently.

**Remediation:**

1. Add a single process abstraction in a shared library module, with APIs for:
   - argv-based execution without a shell;
   - optional shell execution only when required;
   - stdout/stderr capture;
   - timeout support where useful;
   - structured return values containing exit code, stdout, and stderr.
2. Migrate `Sun_cli_shell` and `Sundev_shell` to this abstraction or remove one of them.
3. Convert high-risk call sites first: `kubectl`, `helm`, `git`, and `docker` invocations.
4. Preserve user-facing echo output where commands are intentionally shown.

**Acceptance criteria:**

- There is one shared command runner used by both `cli/sun` and `tools/sundev`.
- Callers that do not need shell features pass argv arrays instead of formatted shell strings.
- Temp-file stdout capture is removed from the shared command helpers.
- Unit tests cover success, non-zero exit, captured stdout/stderr, and command-not-found behavior.

## Review — automated checks passed
Structured Sun_process library added with run/run_argv/lines/output/run_ok/run_rc; Sun_cli_Shell and Sundev_Shell delegate to it; docker build/push converted to run_argv; 15 unit tests all pass; build clean.
