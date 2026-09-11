---
id: CODEX_STYLE_AUDIT-015
type: refactor
severity: medium
branch: CODEX_STYLE_AUDIT-015/flatten-db-results
worktree: ../sun-CODEX-015
source: style audit
---

Flatten storage pool and transaction Result handling.

**Depends on:** none.

**Problem:** `integrations/storage/sun-storage/lib/db.ml:19-72` contains nested
matches for pool creation, callback execution, transaction start, commit, and
rollback. The module already returns `Storage_error.t result`, but the flow is
not expressed as a Result pipeline.

**Goal:** Make database helper control flow linear and consistently typed.

**Acceptance criteria:**

- Introduce local bind/map-error helpers for `Storage_error.t result`.
- Refactor `create_pool`, `exec`, `find`, `collect`, and `transaction` where it
  improves readability.
- Preserve rollback-on-error behavior in `transaction`.
- Existing storage tests continue to pass.

## Review — automated checks passed
Implementation verified correct
