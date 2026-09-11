---
id: CODEX_STYLE_AUDIT-006
type: refactor
severity: high
source: style audit
branch: CODEX_STYLE_AUDIT-006/typed-inspection-fields
worktree: ../sun-CODEX-006
---

Use typed release-inspection fields instead of status, mode, primitive, and kind strings.

**Depends on:** none.

**Problem:** `cli/sun/lib/sun_cli_release_inspection.ml:13-53` stores finite
domains as strings: `environment`, `mode`, `primitive`, `status`, and manifest
`kind`. The module already defines variants for rollout and health status, but
other finite fields bypass the compiler and are serialized directly later.

**Goal:** Keep finite inspection concepts typed until the JSON/string rendering
boundary.

**Acceptance criteria:**

- Replace `mode : string`, `primitive : string`, `status : string`, and
  `kind : string` with variants or existing domain types where possible.
- Keep `*_to_string` conversion functions at the output boundary.
- Update `Sun_cli_hosted_executor` and tests that construct inspection records.
- Ensure JSON output remains backward compatible unless a deliberate migration is
  documented.

## Review — automated checks passed
All three string fields replaced with typed variants, conversions correctly deferred to the JSON boundary, hosted executor and tests updated, build clean, tests pass, no project/tickets changes.
