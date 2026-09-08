---
id: CODEX_STYLE_AUDIT-044
type: refactor
severity: high
source: style audit
---

Replace deployment-plan `secret_backend : string` with the existing backend variant.

**Depends on:** none.

branch: CODEX_STYLE_AUDIT-044/typed-secret-backend-plan
worktree: /home/lbendtly/Code/sun-CODEX-044

**Problem:** `cli/sun/lib/sun_cli_deployment_plan.ml:7-15` defines
`env_config.secret_backend : string`, even though `Sun_cli_manifest.secret_backend`
is a variant. The plan serializes a finite deployment behavior as raw text.

**Goal:** Keep secret backend typed until JSON serialization.

**Acceptance criteria:**

- Change `env_config.secret_backend` to a variant or reuse
  `Sun_cli_manifest.secret_backend`.
- Update env-target conversion and deploy plan JSON rendering.
- Keep existing JSON string values stable.

## Review — automated checks passed
CODEX_STYLE_AUDIT-044 is satisfied: env_config.secret_backend is typed as Sun_cli_manifest.secret_backend in the current codebase, JSON conversion is isolated through a deployment-plan helper using Sun_cli_manifest.secret_backend_to_string, env-target conversion already populates the variant, stable JSON values are covered for kubernetes-live, kubernetes-placeholder, and external-secrets, and focused deployment-plan tests plus CLI build passed. No baseline changes accepted.
