---
id: CODEX_STYLE_AUDIT-022
type: refactor
severity: medium
source: style audit
branch: CODEX_STYLE_AUDIT-022/typed-pipeline-states
worktree: /home/lbendtly/Code/sun-CODEX-022
---

Replace `sundev` pipeline string states with variants.

**Depends on:** none.

**Problem:** `tools/sundev/lib/sundev_ticket.ml:1-9` stores ticket states as raw
strings, and `tools/sundev/lib/sundev_merge.ml:232-234` parses review status
from `"pass"` / `"fail"` strings into polymorphic variants inline. Ticket state,
review outcome, and readiness labels are finite domains.

**Goal:** Make project workflow states typed and parse strings only at file/JSON
boundaries.

**Acceptance criteria:**

- Introduce variants for ticket state and review status.
- Keep path/string conversion helpers near the filesystem boundary.
- Update `find_ticket`, `dependency_status`, list/check commands, and tests.
- Preserve existing on-disk directory names.

## Review — automated checks passed
Build passed. Diff is scoped to sundev ticket/merge code and ticket tests. Ticket states and review statuses are represented as variants internally, conversions are used at filesystem/JSON/user-output boundaries, affected pipeline callers are updated, parser tests pass, project/tickets is untouched, and no new unsafe shell or wrapped true behavior was introduced.
