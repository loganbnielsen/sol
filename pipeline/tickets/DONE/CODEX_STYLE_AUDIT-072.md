---
id: CODEX_STYLE_AUDIT-072
branch: CODEX_STYLE_AUDIT-072/k8s-artifact-invariants
worktree: ../sun-CODEX_STYLE_AUDIT-072-k8s-artifact-invariants
type: refactor
severity: medium
source: docs/audits/STYLE_AUDIT.md
---

Add contributor-facing invariants for generated Kubernetes artifacts.

**Depends on:** CODEX_STYLE_AUDIT-061.

**Problem:** Security and operational invariants such as non-root containers,
read-only filesystems, ClusterIP-only services, NetworkPolicy presence, secret
redaction, and workspace/domain ownership are scattered across manifest tests,
rendering code, and docs.

**Goal:** Make generated artifact invariants obvious and enforce them in one
place.

**Acceptance criteria:**

- Add a documented invariant checklist near manifest rendering or in
  `docs/architecture/devops-pipeline.md`.
- Add a test helper that validates rendered artifacts against these invariants.
- Use the helper across service, worker, function, GitOps, and rollout rendering
  tests.

## Review — automated checks passed
assert_k8s_invariants helper and artifact_invariants suite added for svc/worker/fn/rollout, GitOps redaction test present, devops-pipeline.md invariants table documented, build and all tests pass
