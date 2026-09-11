---
id: CODEX_STYLE_AUDIT-016
type: refactor
severity: medium
branch: CODEX_STYLE_AUDIT-016/flatten-migration-results
worktree: ../sun-CODEX-016
source: style audit
---

Replace migration status folds with Result combinators.

**Depends on:** none.

**Problem:** `integrations/storage/sun-storage/lib/migration.ml:186-252` uses
manual accumulator matches and nested file-read matches in `apply`, `status`,
and `rollback`, despite defining `let* = Result.bind` at the top.

**Goal:** Make migration happy paths obvious and error handling uniform.

**Acceptance criteria:**

- Extract a `read_file_result` helper for migration SQL files.
- Use Result-aware folds or small recursive helpers instead of matching on
  `acc` at each step.
- Keep migration error messages stable enough for current tests.

## Review — automated checks passed
Implementation verified correct
