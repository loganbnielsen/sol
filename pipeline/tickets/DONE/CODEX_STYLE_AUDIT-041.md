---
id: CODEX_STYLE_AUDIT-041
type: refactor
severity: medium
source: style audit
---

Extract reusable event JSON decoders for examples and generated workspaces.

**Depends on:** none.

branch: CODEX_STYLE_AUDIT-041/event-json-decoders
worktree: /home/lbendtly/Code/sun-CODEX-041

**Problem:** `examples/local-demo/lib/events.ml:28-44`,
`examples/pluto/events/payments/charged.ml:31-41`, and Venus event modules all
repeat `get_s`, `get_i`, and tuple-of-options matches for required fields.

**Goal:** Make event decoders linear and field-specific.

**Acceptance criteria:**

- Provide small Result-returning helpers for required string and int fields.
- Use `let*` pipelines in example decoders.
- Report the missing or mistyped field name in errors.
- Update generated event templates to use the same pattern.

## Review — automated checks passed
Implementation satisfies CODEX_STYLE_AUDIT-041: event decoders now use Result-returning required_string/required_int helpers with let* pipelines, errors name missing or mistyped fields, generated event templates use the same pattern, scaffold tests were updated, and focused event builds plus scaffold tests passed. No baseline changes accepted.
