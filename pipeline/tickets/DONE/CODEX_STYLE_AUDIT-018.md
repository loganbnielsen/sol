---
id: CODEX_STYLE_AUDIT-018
type: refactor
severity: medium
source: style audit
branch: CODEX_STYLE_AUDIT-018/flatten-worker-startup
worktree: ../sun-CODEX-018
---

Flatten worker startup create/register/consume flow.

**Depends on:** none.

**Problem:** `framework/sun-worker/lib/worker.ml:109-128` nests test injection,
Kafka service creation, topic registration, and consume startup. The surrounding
handler also nests telemetry and remaining-message handling.

**Goal:** Make worker startup read as a linear Result pipeline with side effects
at clear boundaries.

**Acceptance criteria:**

- Extract the normal Kafka startup path into a helper returning a typed Result.
- Use Result binding for create, register, and consume.
- Keep `_consume_loop` test injection behavior unchanged.
- Existing worker tests continue to pass.

## Review — automated checks passed
Verified correct
