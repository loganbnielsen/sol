---
id: FEAT-006
type: feature
severity: medium
source: PRODUCT_ARCHITECTURE.md
branch: FEAT-006/deployment-executors
worktree: ../sun-FEAT-006-deployment-executors
---

Make deployment executors explicit.

**Depends on:** FEAT-004, FEAT-005.

**Problem:** Apply-vs-emit behavior is currently selected inside command logic. As Sun adds customer-cloud and hosted modes, deploy behavior should be modeled as executors over the same deployment plan rather than branching throughout the CLI.

**Goal:** Introduce explicit executor functions for local apply, direct Kubernetes apply, and GitOps emit.

**Remediation:**

1. Add an executor module or functions that accept a deployment plan.
2. Implement:
   - local Kubernetes executor: apply to current local/k3d context
   - direct Kubernetes executor: apply to current kube context
   - GitOps executor: write manifests to a directory
3. Keep existing `Sun_cli_manifest.apply` and `emit_to_dir` helpers if they remain the right low-level primitives.
4. Update `cmd_up.ml` and `cmd_deploy.ml` to select an executor and pass it a plan.
5. Keep command output compatible with current behavior.

**Out of scope:**

- Hosted executor implementation.
- Terraform provisioning.
- Argo CD API integration.
- Remote cluster authentication management.

**Acceptance criteria:**

- `sun up` uses the local executor.
- `sun deploy` without `--emit-to` uses a direct Kubernetes executor.
- `sun deploy --emit-to DIR` uses a GitOps emit executor.
- The executor boundary is plan-in, side-effect-out.

**Decisions:**

- Executor selection stays implied by `sun up`, `sun deploy`, and `--emit-to`. Users should not need to know the word "executor."
- Direct-k8s and GitOps remain modes of `sun deploy`. `--emit-to` is already the right escape hatch for GitOps; no new subcommands needed.

## Review — automated checks passed
FEAT-006 implemented correctly. Added Sun_cli_executor module (mli + ml) with local, direct, and gitops executor functions. Each executor takes a service_spec, renders YAML via Sun_cli_deployment_plan.render_spec, and dispatches to Sun_cli_manifest.apply or emit_to_dir. cmd_up.ml now uses Sun_cli_executor.local; cmd_deploy.ml uses Sun_cli_executor.direct for direct k8s apply and Sun_cli_executor.gitops when --emit-to is given. Existing Printf output preserved exactly. 7 new unit tests cover all three executors. All pre-commit hooks (build + full test suite including e2e) pass.
