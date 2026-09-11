---
id: CODEX_STYLE_AUDIT-067
branch: CODEX_STYLE_AUDIT-067/devops-pipeline-doc
worktree: ../sun-CODEX_STYLE_AUDIT-067-devops-pipeline-doc
type: refactor
severity: medium
source: docs/audits/STYLE_AUDIT.md
---

Document the deployment pipeline architecture for CI/CD contributors.

**Depends on:** CODEX_STYLE_AUDIT-061.

**Problem:** `docs/architecture/PRODUCT_ARCHITECTURE.md` explains product
architecture, but there is no focused contributor guide that maps CLI commands
to code paths, deployment phases, executor responsibilities, state files,
failure modes, and tests.

**Goal:** Make the codebase approachable to professional CI/CD and infra
contributors.

**Acceptance criteria:**

- Add `docs/architecture/devops-pipeline.md` or equivalent.
- Cover `sun dev up`, `sun up`, `sun deploy`, `sun status`, `sun logs`,
  `sun migrate`, and `sun rollback` code paths.
- Include a request -> plan -> render -> execute -> state diagram.
- Link to relevant tests and explain where new contributors should add tests for
  deployment changes.

## Review — automated checks passed
Documentation-only change; build passes, all 7 commands covered, pipeline diagram present, all module names and test file references verified against actual code
