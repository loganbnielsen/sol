---
id: FEAT-003
type: feature
severity: high
source: PRODUCT_ARCHITECTURE.md
branch: FEAT-003/deployment-plan-model
worktree: /home/lbendtly/Code/sun-FEAT-003-deployment-plan-model
---

Introduce a typed `Deployment_plan` module.

**Depends on:** None.

**Problem:** `sun up` and `sun deploy` both derive workspace name, namespace, k8s resource name, image reference, config, and primitive behavior inline before calling `Sun_cli_manifest.render`. This keeps behavior mostly shared, but the shared contract is still "discovered services plus command-specific arguments" instead of a durable deployment intent model.

**Goal:** Add a typed intermediate deployment plan that represents what Sun intends to run for a workspace and environment. This is the foundation for local deploy, customer-cloud deploy, GitOps emit, and future Sun-hosted execution.

**Remediation:**

1. Add `cli/sun/lib/sun_cli_deployment_plan.ml` and `.mli`.
2. Define plan types for:
   - deployment mode: local, customer cloud, Sun hosted
   - environment identity: name, mode, registry, image tag, optional region/base domain
   - service spec: domain, source name, k8s name, namespace, primitive, source dir, image, config, secrets
   - function schedule for `-fn` services
3. Add deterministic helpers for namespace names, k8s names, and image references.
4. Add `of_services` or equivalent constructor that converts `Sun_cli_manifest.service list` plus environment inputs into a deployment plan.
5. Keep current CLI behavior unchanged.
6. Add focused tests for deterministic naming and image reference construction.

**Out of scope:**

- New CLI commands.
- Hosted control plane API.
- Terraform/Pulumi replacement.
- Full environment config file format.
- Kafka topic/ACL provisioning beyond placeholders if needed by the type shape.

**Acceptance criteria:**

- `dune build` passes.
- Tests verify underscores become hyphens in k8s names, namespaces remain `<workspace>-<domain>`, and images remain compatible with current `sun up` and `sun deploy` behavior.
- No generated YAML changes for existing `sun up --dry-run` and `sun deploy --dry-run` paths.

**Decisions:**

- Topics and migrations: add as empty placeholder fields (`topics: string list`, `migrations: string list`) in the plan type now so the shape is correct, but implement no logic for them. Cheaper to add the field once than refactor later.
- `Sun_cli_manifest.service`: leave where it is. This ticket adds the plan type; module restructuring is a later refactor.

## Review — automated checks passed
Sun_cli_deployment_plan module added correctly: dune build clean, all 8 unit tests pass, (wrapped false) confirmed, no shell injection or unchecked Sys.command, hygiene/tickets/ untouched in worktree branch.
