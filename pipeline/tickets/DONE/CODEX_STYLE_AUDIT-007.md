---
id: CODEX_STYLE_AUDIT-007
type: refactor
severity: medium
source: style audit
branch: CODEX_STYLE_AUDIT-007/typed-hosted-primitives
worktree: ../sun-CODEX-007
---

Stop converting hosted executor primitives to strings inside core records.

**Depends on:** CODEX_STYLE_AUDIT-006.

**Problem:** `cli/sun/lib/sun_cli_hosted_executor.ml:12` and
`cli/sun/lib/sun_cli_hosted_executor.mli:19` store `primitive : string` in
`service_summary`, with conversion at `sun_cli_hosted_executor.ml:24-27`.
Downstream inspection code then repeats similar string conversion.

**Goal:** Store `Sun_cli_deployment_plan.primitive` or a hosted-specific variant
in hosted summaries and stringify only at JSON/API rendering.

**Acceptance criteria:**

- Change `service_summary.primitive` to a variant type.
- Update `service_summaries`, `release_to_json`, and hosted executor tests.
- Remove duplicated primitive string conversion where the inspection module can
  own it.

## Review — automated checks passed
service_summary.primitive correctly promoted to Sun_cli_deployment_plan.primitive; string conversion deferred to JSON boundary; tests updated; build clean
