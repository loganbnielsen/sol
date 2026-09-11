---
id: CODEX_STYLE_AUDIT-060
type: refactor
severity: medium
source: style audit
branch: CODEX_STYLE_AUDIT-060/effective-rollout-strategy
worktree: /home/lbendtly/Code/sun-CODEX-060
---

Make rollout strategy JSON strings come from one typed conversion boundary.

**Depends on:** none.

**Problem:** `cli/sun/lib/sun_cli_deployment_plan.ml:70-79` constructs
`"canary"`, `"blue_green"`, `"recreate"`, and `"rolling_update"` strings from a
mix of progressive delivery and rollout strategy options. The same finite domain
is represented by several optional fields.

**Goal:** Model effective rollout strategy as one variant before JSON rendering.

**Acceptance criteria:**

- Add an `effective_rollout_strategy` variant.
- Derive it once from `service_spec`.
- Use a single `effective_rollout_strategy_to_string` function for JSON and
  summaries.

## Review — automated checks passed
Implementation satisfies the ticket: it adds an effective_rollout_strategy variant, centralizes derivation from service_spec, routes both JSON and summary rendering through effective_rollout_strategy_to_string, and updates summary output with rollout=<strategy>. Targeted deployment plan tests and dune build passed. No correctness, regression, scope, or test adequacy violations found.
