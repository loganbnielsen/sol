---
id: CODEX_STYLE_AUDIT-064
type: refactor
severity: high
source: docs/audits/STYLE_AUDIT.md
branch: CODEX_STYLE_AUDIT-064/typed-tool-adapters
worktree: ../sun-CODEX_STYLE_AUDIT-064-typed-tool-adapters
---

Introduce typed Kubernetes, Docker, Helm, Terraform, and Git command modules.

**Depends on:** CODEX_STYLE_AUDIT-063.

**Problem:** Infra commands are assembled with ad hoc strings throughout the CLI:
kubectl apply/logs/status/port-forward, Docker build/push/inspect, Helm install,
Terraform init/plan/apply/output, and Git SHA lookup. This obscures intent and
duplicates command details.

**Goal:** Give contributors small typed adapters for each external tool.

**Acceptance criteria:**

- Add modules such as `Sun_cli_kubectl`, `Sun_cli_docker`, `Sun_cli_helm`,
  `Sun_cli_terraform`, and `Sun_cli_git` or an equivalent structure.
- Each module exposes typed operations, not raw command strings.
- Existing command modules call these adapters instead of formatting shell
  commands directly.
- Adapter tests verify argv construction and failure propagation.

## Review — automated checks passed
All five typed tool adapter modules exist with labeled-parameter signatures; callers migrated; argv and failure-propagation tests pass; no new Sys.command calls; no wrapped true; project/tickets/ untouched
