---
id: CODEX_STYLE_AUDIT-070
type: refactor
severity: high
source: docs/audits/STYLE_AUDIT.md
branch: CODEX_STYLE_AUDIT-070/secret-strategy
worktree: ../sun-CODEX_STYLE_AUDIT-070-secret-strategy
---

Make secret backend behavior a deployment-phase contract.

**Depends on:** CODEX_STYLE_AUDIT-044.

**Problem:** Secret handling is split between `cmd_deploy.ml`,
`Sun_cli_manifest.secret_backend`, `Sun_cli_deployment_render`, `Sun_cli_secret`,
and GitOps docs. Contributors must trace several modules to answer whether
direct deploy, GitOps placeholder, External Secrets, and hosted secret behavior
can leak plaintext or fail closed.

**Goal:** Define secret handling as an explicit part of environment resolution
and artifact rendering.

**Acceptance criteria:**

- Add a typed `secret_strategy` or equivalent to the deployment plan/environment.
- Document allowed strategies and where values are read.
- Make GitOps plaintext leakage impossible by construction.
- Add tests for Kubernetes live, placeholder, ExternalSecret, and unsupported
  hosted secret paths.

## Review — automated checks passed
Build clean, guard correctly placed before rendering, default_secret_backend maps all 4 targets correctly, tests cover all required cases, docs updated, to_env_config uses default_secret_backend, no project/tickets touched
