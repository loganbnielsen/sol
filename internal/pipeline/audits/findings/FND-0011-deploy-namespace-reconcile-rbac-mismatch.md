# FND-0011 — The deploy identity may create a namespace but not reconcile one, and Sol's own deploy path applies it

- **Classification:** `VERIFIED_DEFECT`
- **State:** `OPEN`
- **First identified:** 2026-09-20, AWS Run 8 step 6 (live)
- **Derived ticket:** `INFRA-048`
- **Invariant:** `INV-AUTH-6` (new — see
  `internal/pipeline/audits/invariants/PROVIDER-NEUTRAL-INVARIANTS.md`)
- **Evidence class:** `BEHAVIORAL` (observed on a live target), with `STATIC`
  corroboration from the RBAC contract and the client code

## What happened

The first deploy that reached Sol's apply step on a live target failed:

```text
error: kubectl apply failed: exited with code 1: ...
  Error from server (Forbidden): error when applying patch:
  {"metadata":{"annotations":{"kubectl.kubernetes.io/last-applied-configuration":
  "{\"apiVersion\":\"v1\",\"kind\":\"Namespace\",\"metadata\":{\"annotations\":{},
  \"name\":\"pluto-checkout\"}}\n"}}}
  to:
  Resource: "/v1, Resource=namespaces", GroupVersionKind: "/v1, Kind=Namespace"
  Name: "pluto-checkout", Namespace: ""
  for: "/tmp/sol-manifest-6ded08.yaml": error when patching
  "/tmp/sol-manifest-6ded08.yaml": namespaces "pluto-checkout" is forbidden:
  User "arn:aws:sts::<account>:assumed-role/sol-qual5-deploy/EKSGetTokenAuth"
  cannot patch resource "namespaces" in API group "" in the namespace "pluto-checkout"
```

Run identity: `qual/aws/us-east-1`, revision `40d00908`, account `<account>` (redacted),
region `us-east-1`, profile `production-single-region/v1`.

## Why it is not an edge case

It is the **prescribed recovery path**, and it is also the first deploy:

1. `sol deploy` → substrate `ensure` runs before the migration gate and creates
   the application namespace with `kubectl create`
   (`Sol_cli_substrate.create_idempotent`).
2. The migration gate refuses, because the declared migration is not applied.
3. The operator follows the deploy's own printed remedy:
   `sol migrate apply <target>`, then deploy again.
4. The second deploy finds the namespace present — created by step 1, with
   `annotations: {}` and therefore **no `last-applied-configuration`** — and
   `kubectl apply` on it degrades to a PATCH, which the identity may not do.

The same holds for a *first* successful deploy: `ensure` creates the namespace
immediately before the apply step applies it, so the apply step always meets a
namespace that already exists and lacks the annotation.

## The two halves, verified

**The RBAC is deliberate, and says so.**
`cli/platform/infra/base/platform_deploy_rbac.tf` grants `sol-deploy-bootstrap`
`namespaces: get,list,watch,create` — "never update/patch/delete, so deploy can
create a namespace that does not yet exist but can never mutate one that already
does — including every platform namespace". It then states the contract the code
must satisfy:

> `Sol_cli_substrate.ensure` treats an "AlreadyExists" response to create as
> success rather than calling `kubectl apply` (which would need patch), so
> idempotent re-application never needs more than this.

`sol_cli_substrate.ml` repeats it: "idempotency here comes from tolerating
'AlreadyExists' on `create`, not from `kubectl apply`'s patch, which this identity
does not have for either kind."

Live confirmation on the target, as the deploy identity itself:

```text
get    namespaces: yes
create namespaces: yes
patch  namespaces: no
update namespaces: no
create deployments -n pluto-checkout: yes
patch  deployments -n pluto-checkout: yes
```

and the namespace object:

```json
{"name":"pluto-checkout","created":"2026-09-20T16:41:16Z",
 "annotations":{},"labels":{"kubernetes.io/metadata.name":"pluto-checkout"}}
```

**The client violates that contract.**
`cli/sol/lib/sol_cli_manifest.ml`:

```ocaml
let apply ~ctx (ns_yaml, workload_yaml) ~dry_run =
  if dry_run
  then Printf.printf "%s\n%s\n" ns_yaml workload_yaml
  else (
    apply_live ~ctx ns_yaml;      (* <-- kubectl apply on the Namespace document *)
    ...
```

`ns_yaml` is exactly the Namespace document
(`Sol_cli_deployment_render.ml`: `let ns_yaml = namespace_doc ~ns`). So the one
code path the RBAC contract says will never be needed — `kubectl apply` on a
namespace — is the one Sol issues.

## Why the boundary should not simply be widened

The obvious "fix" is to grant `patch`/`update` on `namespaces`. The RBAC file
argues against it in writing: a cluster-wide `patch` on namespaces would let the
deploy identity mutate **every** namespace, including the platform's
(`monitoring`, `kube-system`, …), which is the boundary that file exists to hold.
The contract already prescribes the narrower resolution, and the substrate module
already implements it. The defect is that the manifest apply path does not use it.

## What would make this qualified

- `sol deploy` against the production profile reaches its apply step with an
  application namespace that already exists and carries no
  `last-applied-configuration`, and succeeds.
- The deploy identity still cannot `patch`/`update` a namespace, and still cannot
  reach a platform namespace.
- A regression test drives `create → migration gate blocks → migrate apply →
  deploy again` and fails if the apply path ever returns to `kubectl apply` for
  the namespace, rather than asserting a static RBAC list.

## Sources

- Live: Run 8 (`qual/aws/us-east-1`, 2026-09-20), the failure above and the
  `can-i` / namespace-annotation probes.
- `cli/platform/infra/base/platform_deploy_rbac.tf:64-107`
- `cli/sol/lib/sol_cli_substrate.ml:126-209`
- `cli/sol/lib/sol_cli_manifest.ml:149-174`
- `cli/sol/lib/sol_cli_deployment_render.ml:84,344`
