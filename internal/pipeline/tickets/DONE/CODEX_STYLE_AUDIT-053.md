---
id: CODEX_STYLE_AUDIT-053
type: refactor
severity: medium
source: style audit
---

Replace hosted model ID aliases with distinct validated ID types.

**Depends on:** none.

**Problem:** `cli/sun/lib/sun_cli_hosted_model.ml:1-5` defines
`account_id`, `project_id`, `environment_id`, `runtime_id`, and `attribution_id`
as aliases of `string`. The compiler cannot prevent swapping them.

**Goal:** Make hosted ownership boundaries type-safe.

**Acceptance criteria:**

- Replace string aliases with private wrapper types or modules per ID kind.
- Keep validated constructors and string conversion helpers.
- Update hosted model, hosted executor, and tests.

Completion: hosted IDs now use distinct abstract wrapper modules with validated
string constructors and explicit string conversion helpers. Hosted model and
executor JSON/release boundaries unwrap IDs deliberately, focused hosted tests
and the affected CLI build pass, and valid JSON output remains unchanged. No
baseline changes accepted.
