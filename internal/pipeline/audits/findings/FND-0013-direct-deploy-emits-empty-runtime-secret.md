# FND-0013 — A direct deploy emits an empty runtime Secret, so the workload cannot start

- **Classification:** `VERIFIED_DEFECT`
- **State:** `OPEN`
- **First identified:** 2026-09-20, AWS Run 8 step 6 (live, after FND-0011's fix)
- **Derived ticket:** `INFRA-050`
- **Invariant:** `INV-AUTH-6` (an identity/production path may do what Sol asks of it) —
  and, more directly, the credential-posture guarantee: a deployed workload must
  receive the runtime credentials the profile claims it has
- **Evidence class:** `BEHAVIORAL` (live target), with `STATIC` corroboration from
  the two competing defaults

## What happened

With FND-0011 fixed, `sol deploy` succeeded — and the workload it deployed could
not start:

```text
Fatal error: exception Failure("sol-svc: config error: API key auth configured
but SOL_API_KEY/SOL_API_KEY_FILE is not set")
```

The workspace runtime Secret was correct; the per-service Secret the workload
actually reads was not:

| Secret | Keys | Values |
|---|---|---|
| `sol-secrets` (workspace runtime Secret, written by `cloud apply`/`migrate`) | `POSTGRES_URL`, `SOL_API_KEY` | populated (125 / 64 bytes) |
| `checkout-svc-secrets` (per-service Secret, written by `sol deploy`) | `POSTGRES_URL`, `SOL_API_KEY` | **both empty (0 bytes)** |

The Deployment wires it correctly — `envFrom: [configMapRef checkout-svc-env,
secretRef checkout-svc-secrets]` — so the application reads two empty strings and
refuses to run. This is `Kubernetes_placeholder` behaviour: a deliberately
redacted Secret intended for GitOps output.

## Why: two competing defaults

`cli/sol/lib/sol_cli_env_target.ml` already encodes the correct semantic decision:

```ocaml
let default_secret_backend : t -> Sol_cli_manifest.secret_backend = function
  | Local _ -> Sol_cli_manifest.Kubernetes_live
  | Customer_direct _ -> Sol_cli_manifest.Kubernetes_live
  | Customer_gitops _ -> Sol_cli_manifest.Kubernetes_placeholder
  | Sol_hosted _ -> Sol_cli_manifest.Kubernetes_placeholder
```

A target with no explicit destination classifies as `Customer_direct`
(`sol_cli_env_target.ml:33`), so the destination's own answer is
`kubernetes-live`.

The CLI then defeats that abstraction:

```ocaml
(* cli/sol/bin/cmd_deploy.ml:880 *)
let secret_backend_arg =
  Arg.(value & opt string "kubernetes-placeholder" & info [ "secret-backend" ]
    ~doc:"Secret backend for GitOps output. 'kubernetes-placeholder' (default) …
          Only meaningful with --emit-to.")
```

The flag's hard default always supplies a value, so the destination
classification is never consulted. The help text makes it worse by describing the
option as GitOps-only, which contradicts `Customer_direct → Kubernetes_live` and
is why nothing in the qualification procedure says to pass it.

## Why it is not exotic

It is the documented deploy command. HARDEN-002's step 6 is
`sol deploy <target> --image-ref <svc>=<repo>@sha256:<digest>` with no
`--secret-backend`, and `kubernetes-live` appears nowhere in `docs/` or the
tickets except as a name in an audit of style. Following the procedure as written
deploys a workload that cannot start.

## The fix (decided)

Absence of the flag must mean **"use the destination's default"**, not "use this
backend" — one source of truth for the decision, so this class of bug cannot
return:

- an explicitly supplied `--secret-backend` overrides the inferred backend;
- with no explicit override, the destination's `default_secret_backend` applies;
- direct/local therefore resolves to `kubernetes-live`;
- GitOps/emit paths keep their placeholder behaviour.

The fix is **not** to replace one hard-coded default with another. The flag help
must describe an override rather than a GitOps-only option. Tracked as
`INFRA-050`.

## What would make this qualified

Re-running the **documented** step 6 command — with no `--secret-backend` —
against the same target reconciles the existing per-service Secret with the real
runtime values, and the workload starts. The empty Secret is deliberately
preserved until then, because it is the evidence of what the broken version
emitted.

## Sources

- Live: Run 8, deploy `deploy-20260920T201903Z-532619`, revision `642162b4`,
  target `qual/aws/us-east-1`.
- `cli/sol/lib/sol_cli_env_target.ml:33,67-71`
- `cli/sol/bin/cmd_deploy.ml:880-890,942-970`
- `cli/sol/lib/sol_cli_manifest.ml:8-24` (the backend type and its own doc:
  "Kubernetes_live — emit a Kubernetes Secret with real values (live deploy)")
