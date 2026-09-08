---
id: REFAC-010
branch: REFAC-010/secret-backend-variant
worktree: /home/lbendtly/Code/sun-REFAC-010-secret-backend-variant
type: refactor
severity: medium
source: codebase simplification review 2026-06-15
---

Use `Sun_cli_manifest.secret_backend` variant in `env_config` instead of a re-parsed string

**Depends on:** None.

**Description:**

`Sun_cli_manifest.secret_backend` is already a well-typed variant:

```ocaml
(* sun_cli_manifest.ml:5 *)
type secret_backend =
  | Kubernetes_live
  | Kubernetes_placeholder
  | External_secrets of { store_ref : string; store_kind : string; ... }
```

But `env_config` in `sun_cli_deployment_plan.ml` stores it as a plain `string`:

```ocaml
(* sun_cli_deployment_plan.ml:10 *)
type env_config = {
  ...
  secret_backend : string;   (* "kubernetes-placeholder" | "external-secrets" *)
}
```

This creates a two-parse path:

1. `cmd_deploy.ml:19–44` — `parse_secret_backend` converts CLI `string` → `Sun_cli_manifest.secret_backend` variant.
2. `cmd_deploy.ml:47–50` — `secret_backend_to_string` converts variant → `string` to store it in the JSON plan at line 135.
3. `render_spec` (line 342) then receives the `Sun_cli_manifest.secret_backend` variant directly as a parameter — it never reads `env_config.secret_backend` at all.

So `env_config.secret_backend : string` is only used for plan JSON serialization (`sun_cli_deployment_plan.ml:129`), but the variant must then be passed separately to `render_spec`. A developer reading the types cannot tell that `env_config.secret_backend` is never what drives rendering.

**Remediation:**

1. Change `env_config.secret_backend` from `string` to `Sun_cli_manifest.secret_backend`.

2. Update JSON serialization in `sun_cli_deployment_plan.ml` (currently `"secret_backend", `String env.secret_backend` at line 129):
   ```ocaml
   let secret_backend_to_string = function
     | Sun_cli_manifest.Kubernetes_live        -> "kubernetes-live"
     | Sun_cli_manifest.Kubernetes_placeholder -> "kubernetes-placeholder"
     | Sun_cli_manifest.External_secrets _     -> "external-secrets"
   in
   "secret_backend", `String (secret_backend_to_string env.secret_backend)
   ```
   (Move the `secret_backend_to_string` from `cmd_deploy.ml` to `sun_cli_deployment_plan.ml`.)

3. In `cmd_deploy.ml`, delete `secret_backend_to_string` and remove the separate `secret_backend` binding — instead set `env_config.secret_backend` directly to the parsed variant.

4. Anywhere `render_spec` is called with `~secret_backend`, read it from `plan.environment.secret_backend` rather than re-threading it as a separate argument.

**Acceptance criteria:**

- `env_config.secret_backend` has type `Sun_cli_manifest.secret_backend`.
- `cmd_deploy.ml` contains no `secret_backend_to_string` function.
- `parse_secret_backend` in `cmd_deploy.ml` returns `Sun_cli_manifest.secret_backend` and assigns it directly into `env_config`.
- `dune build` passes.
- `sun deploy --dry-run` produces the same YAML as before.

## Review — automated checks passed
env_config.secret_backend is now typed as Sun_cli_manifest.secret_backend, secret_backend_to_string removed from cmd_deploy.ml, parse_secret_backend returns the variant directly, dune build passes, project/tickets/ untouched
