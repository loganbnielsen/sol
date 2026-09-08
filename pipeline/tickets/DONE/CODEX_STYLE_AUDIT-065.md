---
id: CODEX_STYLE_AUDIT-065
type: refactor
severity: high
source: docs/audits/STYLE_AUDIT.md
branch: CODEX_STYLE_AUDIT-065/phase-oriented-tests
worktree: ../sun-CODEX_STYLE_AUDIT-065-phase-oriented-tests
---

Split deployment planning, rendering, and execution tests by phase.

**Depends on:** CODEX_STYLE_AUDIT-061.

**Problem:** Current tests cover pieces of deployment plan, manifest rendering,
and executors, but the contributor mental model is still tied to CLI workflows.
Infra contributors need confidence that plan generation, YAML rendering, GitOps
emit, and direct apply are separately testable phases.

**Goal:** Add phase-oriented tests that document the deployment compiler
contract.

**Acceptance criteria:**

- Add tests named around phases: request validation, plan construction, render
  artifacts, GitOps emit, direct executor command construction, state update.
- Ensure render/plan tests do not require Docker or Kubernetes.
- Add regression tests that local, direct, GitOps, and hosted paths consume the
  same service plan shape.

## Review — automated checks passed
Phase-oriented test suite fully implemented: all 6 required phases present, build clean, tests pass, no Docker/kubectl calls, no project/tickets changes, no wrapped true in dune files.
