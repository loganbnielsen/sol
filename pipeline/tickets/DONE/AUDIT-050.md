---
id: AUDIT-050
type: audit-finding
severity: medium
source: codebase review 2026-06-14
branch: AUDIT-050/cli-port-forward-module
worktree: /home/lbendtly/Code/sun-AUDIT-050-cli-port-forward-module
---

Extract shared CLI port-forward management out of command entry points

**Depends on:** None.

**Description:** `cli/sun/bin/cmd_dev.ml` and `cli/sun/bin/cmd_up.ml` both contain port-forward state and process management logic. `cmd_dev.ml` owns `state_dir`, PID files, wrapper script generation, `start_port_forward`, and cleanup. `cmd_up.ml` repeats the same state directory and PID conventions, plus separate script/log helpers, liveness checks, stale-forward detection, `/proc` parsing, and process probing.

**Impact:** The main command modules have unclear entry points because they mix CLI parsing, workspace orchestration, shell process management, and port-forward lifecycle code. Behavior can drift between `sun dev up` and `sun up`; for example, wrapper script layout, PID validation, log paths, and liveness checks are implemented separately.

**Remediation:**

1. Create a shared library module such as `Sun_cli_port_forward`.
2. Move state directory resolution, PID/log/script path generation, wrapper script creation, liveness checks, stale-forward detection, and cleanup into that module.
3. Have `cmd_dev.ml` and `cmd_up.ml` call the shared API instead of embedding local copies.
4. Add focused unit tests for:
   - state directory selection;
   - wrapper script rendering;
   - PID file cleanup;
   - stale port-forward detection from representative argv lists.

**Acceptance criteria:**

- `cmd_dev.ml` and `cmd_up.ml` no longer define duplicate `state_dir`, `pid_file`, or port-forward wrapper rendering logic.
- Existing `sun dev up/down/status` and `sun up` behavior is preserved.
- New tests cover the shared module without requiring a live Kubernetes cluster.
- Command modules read as orchestration entry points rather than low-level process managers.

## Review — automated checks passed
AUDIT-050 is complete and correct. The shared Sun_cli_port_forward module consolidates all port-forward logic previously duplicated across cmd_dev.ml and cmd_up.ml. Both callers delegate via thin aliases. Build is clean, (wrapped false) is maintained, project/tickets/ is absent from the diff, and all 16 new unit tests pass.
