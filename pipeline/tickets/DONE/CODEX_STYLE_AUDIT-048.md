---
id: CODEX_STYLE_AUDIT-048
type: refactor
severity: medium
source: style audit
---

Make `sun.toml` loading return Result instead of raising `Failure`.

**Depends on:** none.

branch: CODEX_STYLE_AUDIT-048/toml-load-result
worktree: /home/lbendtly/Code/sun-CODEX-048

**Problem:** `cli/sun/lib/sun_cli_toml.ml` parses finite domains and validation
errors, but reports them with `failwith`. Callers cannot distinguish malformed
TOML from other exceptions through the type.

**Goal:** Make TOML parsing errors explicit and typed.

**Acceptance criteria:**

- Change or add a `load_result : string -> (t, parse_error) result`.
- Keep `load` as a compatibility wrapper if needed.
- Update deployment-plan creation paths to surface parse errors cleanly.

## Review — automated checks passed
Implementation satisfies CODEX_STYLE_AUDIT-048: Sun_cli_toml exposes load_result returning typed Toml_syntax/Validation errors, load remains a compatibility wrapper, deployment-plan construction has of_services_result and deploy/up commands surface parse errors cleanly, and focused CLI build plus deployment-plan/manifest-render tests passed. No baseline changes accepted.
