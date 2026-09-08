---
id: FEAT-005
type: feature
severity: high
source: PRODUCT_ARCHITECTURE.md
branch: FEAT-005/environment-target-model
worktree: ../sun-FEAT-005-environment-target-model
---

Add a minimal environment target model for local and customer-cloud deploys.

**Depends on:** FEAT-003.

**Problem:** Sun needs to support both "host with Sun" and "host yourself" without becoming Terraform. Today, registry and environment assumptions are CLI flags or hard-coded defaults. There is no typed boundary between application-owned deployment intent and environment-owned substrate inputs.

**Goal:** Introduce a minimal environment target model that provides deployment inputs without trying to provision cloud infrastructure.

**Remediation:**

1. Add environment target types for:
   - local k3d
   - customer Kubernetes direct
   - customer Kubernetes GitOps
   - future Sun hosted placeholder
2. Represent environment-owned inputs:
   - registry
   - image tag
   - optional region
   - optional base domain
   - Kafka endpoint/security settings
   - Postgres secret reference or placeholder
   - observability endpoints
3. Keep existing CLI flags working: `--registry`, `--image-tag`, `--emit-to`, `--dry-run`.
4. Add internal constructors for current local defaults and current CI/customer-cloud defaults.
5. Feed the environment target into deployment-plan construction.

**Out of scope:**

- Creating AWS/GCP resources.
- Managing IAM, VPCs, DNS zones, RDS, MSK, EKS, or GKE.
- Final hosted environment API.
- A complete `sun.env.toml` format unless agreed separately.

**Acceptance criteria:**

- Existing deploy behavior remains unchanged.
- Environment-owned values are no longer scattered across `cmd_up.ml`, `cmd_deploy.ml`, and manifest rendering.
- Code makes it explicit which values come from the workspace and which values come from the target environment.

**Decisions:**

- Environment file: CLI/env-var only for the first version. Do not design a file format before the contents are known.
- Customer-cloud: first-class happy path in docs, not buried as an advanced path. Sun is "opinionated with escape hatches" and self-hosted is a real supported mode.
- Secrets interface: Kubernetes secret names only for v1. It is the most common case and maps cleanly to what the deployment plan needs to reference.

## Review — automated checks passed
Sun_cli_env_target module correctly consolidates environment-owned inputs (registry, image_tag, target variant), CLI flags are preserved, build and unit tests pass clean, hygiene/tickets/ untouched in branch diff
