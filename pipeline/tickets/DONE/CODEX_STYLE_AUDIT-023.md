---
id: CODEX_STYLE_AUDIT-023
type: refactor
severity: medium
source: style audit
branch: CODEX_STYLE_AUDIT-023/typed-route-patterns
worktree: /home/lbendtly/Code/sun-CODEX-023
---

Replace route pattern strings with a typed route pattern representation.

**Depends on:** none.

**Problem:** `framework/sun-svc/lib/route.ml:4-15` stores route patterns as raw
strings, and `route.ml:34-60` reparses `":"` parameters at match time. Bad
patterns compile and only fail by convention.

**Goal:** Parse route patterns at construction time and expose a typed pattern to
the router.

**Acceptance criteria:**

- Add a `Route.pattern` type with literal and parameter segments.
- Make `get`, `post`, `put`, `patch`, and `delete` parse and validate patterns.
- Preserve the current public ergonomics or provide a clear migration helper.
- Update route tests to cover malformed patterns and parameter extraction.

## Review — automated checks passed
Build passes. Diff is scoped to sun-svc route/service/tests only. The branch adds typed Route.pattern segments, parses and validates string patterns at route construction, uses pre-parsed Param/Literal segments during matching, preserves original pattern strings for metrics labels, and includes malformed-pattern plus param extraction coverage. No project/tickets or perf baseline diffs and no unsafe shell changes found.
