---
id: CODEX_STYLE_AUDIT-002
type: refactor
severity: high
branch: CODEX_STYLE_AUDIT-002/noop-satisfied-by-refac-058
worktree: ../sun-CODEX-002
source: style audit
---

Type the `sun deploy` secret backend parser instead of passing a string mode.

**Depends on:** none.

**Problem:** `cli/sun/bin/cmd_deploy.ml:19` takes six positional parameters:
`backend_str store_ref store_kind key_prefix refresh_interval emit_to`. It then
matches raw CLI strings at `cmd_deploy.ml:20-39`. This combines positional debt
with a stringly finite domain for `--secret-backend`.

**Goal:** Move backend selection to a typed boundary before deployment logic.

**Acceptance criteria:**

- Introduce a CLI-facing variant for secret backend choices before calling
  `parse_secret_backend`.
- Change `parse_secret_backend` to use labeled arguments, for example
  `~backend ~store_ref ~store_kind ~key_prefix ~refresh_interval ~emit_to ()`.
- Keep all unknown-string handling at the Cmdliner conversion boundary.
- Preserve the current warning/error behavior for unsupported combinations.

## Review — automated checks passed
Implementation verified correct
