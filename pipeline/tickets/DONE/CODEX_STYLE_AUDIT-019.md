---
id: CODEX_STYLE_AUDIT-019
type: refactor
severity: low
source: style audit
branch: CODEX_STYLE_AUDIT-019/flatten-fn-runner
worktree: ../sun-CODEX-019
---

Untangle function runner outcome and metric publishing flow.

**Depends on:** none.

**Problem:** `framework/sun-fn/lib/fn.ml:70-86` separately matches on function
outcome for metrics, Pushgateway publishing, and final exit behavior. Push
errors are swallowed intentionally, but the nested `try` / `match` structure
makes that policy easy to miss.

**Goal:** Represent function execution outcome once and centralize the output
effects.

**Acceptance criteria:**

- Introduce helpers for recording metrics and pushing metrics.
- Keep push failures non-fatal.
- Keep final behavior unchanged: success returns, user error raises, signal exits
  130.

## Review — automated checks passed
Verified correct
