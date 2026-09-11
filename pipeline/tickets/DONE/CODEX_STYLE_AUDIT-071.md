---
id: CODEX_STYLE_AUDIT-071
branch: CODEX_STYLE_AUDIT-071/ci-workflow-contract
worktree: ../sun-CODEX_STYLE_AUDIT-071-ci-workflow-contract
type: refactor
severity: medium
source: docs/audits/STYLE_AUDIT.md
---

Make generated CI workflows use the same typed deployment contract as the CLI.

**Depends on:** CODEX_STYLE_AUDIT-061.

**Problem:** Generated GitHub Actions templates in
`cli/sun/lib/sun_cli_scaffold_templates.ml` manually build and push Docker images
before invoking Sun deploy behavior. The CI path can drift from the CLI pipeline
and is hard to reason about as a supported product surface.

**Goal:** Treat scaffolded CI as a thin wrapper around Sun's typed deployment
contract.

**Acceptance criteria:**

- Document the intended generated CI flow in code comments and docs.
- Ensure generated workflows use stable Sun commands for plan/deploy where
  possible instead of duplicating logic.
- Add scaffold tests that assert workflow steps match the deployment pipeline
  contract.

## Review — automated checks passed
CI workflow contract added correctly: Phase 1/2 comment block, sun deploy references, TODO(sun-build) marker, matching tests, and architecture doc — build clean, no violations
