---
id: CODEX_STYLE_AUDIT-017
type: refactor
severity: high
source: style audit
branch: CODEX_STYLE_AUDIT-017/flatten-dispatch
worktree: ../sun-CODEX-017
---

Flatten service dispatch authentication and body parsing.

**Depends on:** none.

**Problem:** `framework/sun-svc/lib/service.ml:63-120` handles method parsing,
built-in routes, route lookup, auth validation, body limits, and trace extraction
through nested matches. The path for a normal user route is hard to scan.

**Goal:** Separate routing decisions from auth/body Result handling.

**Acceptance criteria:**

- Introduce helper functions for built-in route handling, route auth, and body
  extraction.
- Use Result or Option combinators for auth/body steps where practical.
- Preserve all existing HTTP statuses and test expectations.

## Review — automated checks passed
Verified correct
