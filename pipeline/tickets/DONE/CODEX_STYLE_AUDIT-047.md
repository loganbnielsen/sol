---
id: CODEX_STYLE_AUDIT-047
type: refactor
severity: high
source: style audit
branch: CODEX_STYLE_AUDIT-047/env-target-variants
worktree: ../sun-CODEX_STYLE_AUDIT-047-env-target-variants
---

Refactor environment targets into mode-specific records.

**Depends on:** CODEX_STYLE_AUDIT-044.

**Problem:** `cli/sun/lib/sun_cli_env_target.ml:22-53` uses one record with many
optional fields and a `target` tag. Runtime validation then decides which fields
matter for local, customer direct, GitOps, and hosted modes.

**Goal:** Encode mode-specific requirements in constructors and variant payloads.

**Acceptance criteria:**

- Replace the flat record with variants carrying the fields required by each
  target mode.
- Remove validation checks that become impossible states.
- Update accessors and `to_env_config`.

## Review — automated checks passed
Flat record replaced with four constructors carrying mode-specific required fields; validate removed; to_env_config and all callers compile; build and tests green
