---
id: AUDIT-039
type: audit-finding
severity: high
source: project/audits/2026-06-12i_audit.md
branch: AUDIT-039/rollout-secret-ref
worktree: /home/lbendtly/Code/sun-AUDIT-039-rollout-secret-ref
---
**Depends on:** None.

## `rollout_doc` references `sun-secrets` instead of `<name>-secrets` in envFrom secretRef

**Description:** `rollout_doc` in `cli/sun/lib/sun_cli_manifest.ml` (line 419) renders the `envFrom.secretRef.name` as the hardcoded constant `runtime_secret_name` = `"sun-secrets"`. The `secret_doc` helper creates the Secret resource as `<name>-secrets` (e.g., `charge-svc-secrets`). `deployment_doc` (the standard non-progressive path) correctly uses `name` in its format string to produce `<name>-secrets`. The divergence is on line 419: the positional argument for the `envFrom.secretRef` slot passes `runtime_secret_name` rather than `name`.

**Impact:** Any service configured with `[infra.rollout] strategy = "canary"` or `"blue-green"` generates an Argo Rollout resource that references a Secret named `sun-secrets` which does not exist in the namespace. The Kubernetes control plane accepts the manifest on `kubectl apply` (Secret references are not validated at apply time), but pod scheduling fails with a `SecretNotFound` error. `POSTGRES_URL` and all other secrets are not injected into the pod environment. The service crashes at startup. Progressive delivery is silently broken for all workloads that use `[infra.rollout]`.

**Remediation:** In `rollout_doc`, change the `envFrom.secretRef` format specifier from the hardcoded `runtime_secret_name` to use the `name` argument, exactly as `deployment_doc` does.

In `cli/sun/lib/sun_cli_manifest.ml`, locate the `rollout_doc` format string near line 408:
```
        - secretRef:
            name: %s
```
Change to:
```
        - secretRef:
            name: %s-secrets
```
And in the positional argument list at line 419, replace the `runtime_secret_name` argument for this slot with `name`:
```ocaml
...name runtime_secret_name cpu...
```
becomes:
```ocaml
...name name cpu...
```
(removing `runtime_secret_name` from this position and relying on `%s-secrets` in the format string instead).

Also audit `render_secret_key_refs` (line 225): if per-key `secretKeyRef` entries from `[infra.env] secrets = [...]` are also intended to reference `<name>-secrets` rather than a global `sun-secrets`, propagate `name` into that function and update it accordingly. This secondary path is lower urgency since `[infra.env] secrets` usage is uncommon, but should be consistent with the `envFrom` fix.

Add a test in the existing manifest tests that exercises `rollout_doc` with `Canary` and `Blue_green` strategies and asserts the generated `secretRef.name` equals `<service-name>-secrets`.

## Review — returned for revision
- `cli/sun/test/test_manifest_render.ml:197` — test_svc_secret_refs_without_values still asserts `name: sun-secrets`; after the fix render_secret_key_refs emits `name: charge-svc-secrets`, so this assertion must be updated to `name: charge-svc-secrets`.
- `cli/sun/test/test_manifest_render.ml:455` — test_rollout_canary_secrets_use_sun_secrets asserts `name: sun-secrets` (old broken behaviour) and asserts absence of `name: charge-svc-secrets`; both assertions are inverted after the fix and must be swapped.
- `cli/sun/test/test_manifest_render.ml:469` — test_rollout_blue_green_secrets_use_sun_secrets asserts `name: sun-secrets` (old broken behaviour) and asserts absence of `name: charge-svc-secrets`; both assertions are inverted after the fix and must be swapped.

## Review — automated checks passed
Build clean, all tests pass. render_secret_key_refs now takes ~name and emits %s-secrets (name-scoped). rollout_doc envFrom secretRef and secretKeyRef both use name-secrets. deployment_doc and cronjob_doc updated. Tests updated to assert charge-svc-secrets present and sun-secrets absent. No project/tickets touched.
