---
id: CODEX_STYLE_AUDIT-009
type: refactor
severity: medium
source: style audit
branch: CODEX_STYLE_AUDIT-009/flatten-control-plane
worktree: ../sun-CODEX-009
---

Flatten control-plane request parsing with Result and Option helpers.

**Depends on:** none.

**Problem:** `cli/sun/lib/sun_cli_control_plane.ml:59-139` chains body parsing,
JSON field lookups, registry operations, pagination, and routing through nested
`match` blocks. The happy path is visually buried, and missing JSON fields are
handled differently across endpoints.

**Goal:** Make control-plane handlers read as linear Result pipelines.

**Acceptance criteria:**

- Introduce local `let*` helpers for Result and Option-to-Result conversion.
- Refactor project creation, release creation, pagination, and log retrieval
  handlers to use the helpers.
- Keep HTTP status mapping explicit and covered by existing control-plane tests.

## Review — automated checks passed
Flattened control-plane handlers using let* / Option.to_result; build clean, all 10 control-plane tests pass, changes confined to cli/sun/lib/sun_cli_control_plane.ml, no ticket files in worktree.
