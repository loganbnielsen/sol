---
id: FEAT-009
type: feature
severity: medium
source: PRODUCT_ARCHITECTURE.md
branch: FEAT-009/escape-hatches
worktree: ../sun-FEAT-009-escape-hatches
---

Define supported escape hatches for generated infrastructure.

**Depends on:** FEAT-004, FEAT-005.

**Problem:** Sun should be opinionated enough to provide secure infrastructure out of the box, but not so rigid that teams are trapped when they need custom deployment behavior. Today, `sun.toml` supports a few high-level overrides, and `sun deploy --emit-to` lets teams patch generated YAML outside Sun, but the supported escape-hatch model is not explicit.

**Goal:** Define and implement the first supported escape hatches that preserve Sun's application model while allowing controlled customization.

**Remediation:**

1. Document the escape-hatch hierarchy:
   - high-level `sun.toml` overrides for common service needs
   - environment target inputs for substrate-specific values
   - GitOps emit for advanced manifest patching outside Sun
   - raw Kubernetes/Terraform as advanced self-managed paths
2. Decide which additional `sun.toml` overrides are supported first, such as:
   - rollout strategy
   - resource limits/requests beyond current CPU/memory fields
   - environment config refs
   - ingress host/path
   - annotations/labels with guardrails
3. Implement only the agreed first batch.
4. Add validation so unsupported or dangerous overrides fail clearly.
5. Update docs to distinguish normal Sun paths from advanced escape hatches.

**Out of scope:**

- Arbitrary YAML patching in `sun.toml` unless explicitly chosen.
- Supporting every Kubernetes field.
- Replacing Helm/Kustomize.
- Provider-specific Terraform customization.

**Acceptance criteria:**

- Users have a documented way to customize common deployment needs without forking generated manifests.
- Advanced users can still use `--emit-to` and external GitOps tooling.
- Sun continues to own secure defaults and rejects overrides that break core safety invariants.

**Decisions:**

- Typed high-level overrides only. Arbitrary YAML patches make Sun's contract meaningless.
- Non-overridable invariants: non-root, no NodePort, secret handling. Network policy and read-only root filesystem may be configurable in a later iteration.
- Escape hatches are available in both hosted and self-hosted modes. The escape-hatch model is about the application layer, not the hosting layer.

## Review — automated checks passed
FEAT-009 implements the escape-hatch model completely and correctly. Four typed overrides added to sun.toml: rollout_strategy (Recreate/RollingUpdate with validation), ingress_host, ingress_path, and extra_labels (with sun.dev/ namespace guardrail). All fields plumbed through Sun_cli_toml -> Sun_cli_manifest -> Sun_cli_deployment_plan with correct defaults. 12 new tests cover all hatches plus both validation error paths. Parity test (render_spec == render) continues to pass. Full suite green including e2e. docs/escape-hatches.md documents the four-level hierarchy with a supported-overrides table, non-overridable invariants, and usage guidance.
