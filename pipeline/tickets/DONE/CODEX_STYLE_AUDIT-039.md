---
id: CODEX_STYLE_AUDIT-039
type: refactor
severity: medium
source: style audit
branch: CODEX_STYLE_AUDIT-039/bounded-table-pagination
worktree: /home/lbendtly/Code/sun-CODEX-039
---

Use bounded pagination types for storage table listing.

**Depends on:** none.

**Problem:** `integrations/storage/sun-storage/lib/table.ml:42-43` accepts
`?limit:int` and `?offset:int` and passes them directly to SQL. Negative values
or extreme limits compile and depend on database behavior.

**Goal:** Validate pagination inputs at the API boundary.

**Acceptance criteria:**

- Add small validated types or Result-returning constructors for limit and
  offset.
- Keep ergonomic defaults for existing callers.
- Add tests for negative offset and non-positive limit.

## Review — automated checks passed
Implementation satisfies the acceptance criteria. It adds validated Limit and Offset constructors, preserves the existing ergonomic ?limit:int/?offset:int list API and defaults, and adds tests for non-positive limits and negative offsets. The added Limit.max_value = 10000 is within ticket scope because the problem statement explicitly calls out extreme limits depending on database behavior. Focused storage tests and dune build passed.
