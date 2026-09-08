---
id: CODEX_STYLE_AUDIT-062
type: refactor
severity: high
source: docs/audits/STYLE_AUDIT.md
branch: CODEX_STYLE_AUDIT-062/typed-command-requests
worktree: ../sun-CODEX_STYLE_AUDIT-062-typed-command-requests
---

Convert `sun up` and `sun deploy` CLI inputs into typed command requests.

**Depends on:** CODEX_STYLE_AUDIT-061.

**Problem:** `cli/sun/bin/cmd_up.ml:38` and `cli/sun/bin/cmd_deploy.ml:49-51`
accept many Cmdliner-provided parameters directly in their command bodies. This
makes it hard to see which values are external CLI inputs, which are derived
defaults, and which are validated deployment facts.

**Goal:** Treat CLI parsing as an IO boundary that produces typed request
records before domain logic starts.

**Acceptance criteria:**

- Add request types such as `up_request` and `deploy_request` with meaningful
  fields and validation constructors.
- Keep raw strings/options from Cmdliner at the edge; convert them before
  calling deployment pipeline code.
- Ensure command bodies read as parse/validate -> plan -> execute.
- Preserve existing flags and behavior.

## Review — automated checks passed
Typed request records for sun up and sun deploy implemented correctly; build and tests pass; ticket dir untouched
