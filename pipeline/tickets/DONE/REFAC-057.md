---
id: REFAC-057
type: audit-finding
severity: medium
source: ocaml-type-safety-audit 2026-06-16
branch: REFAC-057/typed-secret-backend
worktree: ../sun-REFAC-057-typed-secret-backend
---

Change `env_config.secret_backend` from `string` to `Sun_cli_manifest.secret_backend`

**Depends on:** None.

**Description:**

`cli/sun/lib/sun_cli_deployment_plan.ml:10`:

```ocaml
type env_config = {
  ...
  secret_backend : string;
  ...
}
```

`Sun_cli_manifest.secret_backend` is already a proper variant:

```ocaml
type secret_backend =
  | Kubernetes_live
  | Kubernetes_placeholder
  | External_secrets of { store_ref : string; store_kind : string; ... }
```

Storing it as a string in `env_config` means:
- `test_deployment_plan.ml:134` hard-codes `secret_backend = "kubernetes-placeholder"` in test fixtures — a string that must match what `cmd_deploy.ml` would produce.
- `cmd_deploy.ml:47–50` defines `secret_backend_to_string` to convert back from the variant, which proves the round-trip exists but is done manually.
- `env_config.to_json` at line 129 serializes it directly as the raw string — `"secret_backend", \`String env.secret_backend` — meaning the JSON representation is whatever string was stored, with no canonical form enforced.

**Remediation:**

1. Change `env_config.secret_backend : string` to `secret_backend : Sun_cli_manifest.secret_backend`.
2. Update `env_config.to_json` to call `secret_backend_to_string` (already defined in `cmd_deploy.ml`; move it to `sun_cli_manifest.ml` or `sun_cli_deployment_plan.ml` to avoid a cross-module dependency on `cmd_deploy`).
3. Update `cmd_deploy.ml` to store `secret_backend` (the typed value) directly in `env_config` instead of `secret_backend_str`.
4. Update test fixtures in `test_deployment_plan.ml` to use the constructor: `secret_backend = Sun_cli_manifest.Kubernetes_placeholder`.

## Review — automated checks passed
All ticket requirements met: secret_backend_to_string added to sun_cli_manifest.ml/.mli, env_config.secret_backend typed, to_json uses converter, env_target uses variant, cmd_deploy.ml uses typed value, all test fixtures updated, build clean.
