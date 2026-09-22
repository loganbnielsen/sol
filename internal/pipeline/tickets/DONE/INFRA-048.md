---
id: INFRA-048
type: bug
severity: high
title: The deploy path applies the Namespace with kubectl apply, which the deploy identity may not do
source: audit finding FND-0011 — live AWS Run 8 step 6
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0011-deploy-namespace-reconcile-rbac-mismatch.md`

## The defect

`sol deploy` against the production profile cannot reach a running workload.
Its apply step runs `kubectl apply` over the Namespace document:

```ocaml
(* cli/sol/lib/sol_cli_manifest.ml *)
let apply ~ctx (ns_yaml, workload_yaml) ~dry_run =
  ...
    apply_live ~ctx ns_yaml;
```

but the identity that runs the deploy may only **create** namespaces:

```terraform
(* cli/platform/infra/base/platform_deploy_rbac.tf, sol-deploy-bootstrap *)
resources = ["namespaces"]
verbs     = ["get", "list", "watch", "create"]
```

That grant is deliberate — it is what stops the deploy identity mutating a
namespace it does not own, including every platform namespace. The contract then
states the assumption the code must honour:

> `Sol_cli_substrate.ensure` treats an "AlreadyExists" response to create as
> success rather than calling `kubectl apply` (which would need patch), so
> idempotent re-application never needs more than this.

`Sol_cli_substrate.ensure` does exactly that (`create_idempotent`). The manifest
apply path does not, so it issues the one request the contract says will never be
needed. Observed live:

```text
namespaces "pluto-checkout" is forbidden: User
"arn:aws:sts::<account>:assumed-role/sol-qual5-deploy/EKSGetTokenAuth"
cannot patch resource "namespaces" in API group "" ...
```

It is not an edge case. `ensure` creates the namespace before the migration gate,
so the apply step *always* meets an existing namespace with no
`last-applied-configuration` — including on the first deploy, and certainly when
an operator follows the deploy's own printed remedy (`sol migrate apply`, then
deploy again).

## The fix

Make the apply path use the same create-idempotent mechanism the contract
prescribes, instead of widening the RBAC. The narrow shape:

- move the create-with-`AlreadyExists`-tolerance primitives where both the
  substrate and the manifest apply path can share them (the substrate already
  depends on `Sol_cli_manifest`, so the primitive belongs in the lower module);
- `Sol_cli_manifest.apply` creates the namespace idempotently rather than
  applying it;
- **do not** add `patch`/`update`/`delete` on `namespaces` to
  `sol-deploy-bootstrap`. A cluster-wide patch on namespaces would let the deploy
  identity mutate platform namespaces, which is the boundary that role exists to
  hold. Widening it needs its own justification, not this ticket.

## Acceptance criteria

1. A deploy against the production profile succeeds when the application
   namespace already exists and carries no `last-applied-configuration` — the
   exact live state Run 8 left behind.
2. The deploy identity still cannot `patch`, `update` or `delete` a namespace,
   and still cannot reach a platform namespace. `sol-deploy-bootstrap`'s verbs for
   `namespaces` are unchanged.
3. A **behavioural** regression test drives the observed lifecycle —
   first deploy creates the namespace, the migration gate blocks, migrations are
   applied, the next deploy reconciles the existing namespace and succeeds —
   with the fake kubectl refusing `apply`/`patch` on namespaces exactly as the
   live role does. The test must fail if the apply path returns to
   `kubectl apply` for the namespace; asserting a static RBAC list is not
   sufficient.
4. The offline production-infra check
   (`cli/sol/test/check_production_infra.sh`) continues to pin the boundary.

## Completion — verified close-out (2026-09-22)

**The work landed in #388 (`642162b4`) and the ticket was never moved to DONE**, so
it kept reporting as actionable. Closed here after checking each criterion against
the code rather than assuming the comment meant it was done:

1. `Sol_cli_manifest.create_idempotent` (`sol_cli_manifest.ml:149-170`) creates the
   namespace with `Sol_cli_kubectl.create` and tolerates `AlreadyExists`;
   `Sol_cli_manifest.apply` calls it instead of applying the Namespace document.
2. `platform_deploy_rbac.tf` still grants exactly
   `verbs = ["get", "list", "watch", "create"]` for `namespaces` — no
   `patch`/`update`/`delete`.
3. `cli/sol/test/test_substrate.ml:164-` drives the lifecycle with a fake kubectl
   that refuses `apply` on a namespace (`cannot patch resource "namespaces"`) and
   answers `AlreadyExists` to `create`, exactly as the live role does. Returning the
   apply path to `kubectl apply` fails it.
4. `check_production_infra.sh` passes (run during this close-out).

**Not verified live.** Criterion 1's live condition was Run 8's cluster state; the
next qualification run is what re-observes it, and `FND-0011` stays
`FIXED_UNQUALIFIED` until then.
