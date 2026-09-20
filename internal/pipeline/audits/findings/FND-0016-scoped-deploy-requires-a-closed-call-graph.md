# FND-0016 — A scoped deploy requires its call graph to be inside the scope, so no route deploys this workspace's services

- **Classification:** `VERIFIED_DEFECT`
- **State:** `OPEN`
- **First identified:** 2026-09-20, AWS Run 8 (live)
- **Derived ticket:** none yet — this needs a product decision first (see "The decision")
- **Invariant:** `INV-IDENT-1` (producer/consumer identity agreement) is adjacent, but the
  stronger reading is a scope-contract question: what a selection is allowed to
  *reference* versus what it *contains*
- **Evidence class:** `BEHAVIORAL` (live) + `STATIC` (the resolver and the plan builder)

## What happened

Deploying a service on its own fails if that service calls another one:

```console
$ sol deploy qual/aws/us-east-1 --scope payments/charge_svc --image-ref …
error: service "charge_svc" calls "checkout/checkout_svc": target service not found
```

`checkout/checkout_svc` exists, is deployed, and is healthy. The message reads as
if it does not exist at all.

## Why

Two pieces of code, each internally reasonable:

**The scope resolver** (`sol_cli_deployment_scope.ml`) answers "what does this
release contain", and for a named unit it answers exactly one unit — no widening:

```ocaml
| Unit_named (domain, name) ->
  (match List.find_opt (fun unit -> equal_unit unit domain name) units with
   | Some unit -> Ok (Unit { … }, Selected [ unit ])      (* exactly one *)
   | None -> Error …)
```

**The plan builder** (`sol_cli_deployment_plan.ml`) resolves each call reference
against the units it was given — the *selection*:

```ocaml
let lookup_call caller ref =
  … List.find_opt (fun (svc, _) -> … svc.domain = domain && svc.name = source_name …) loaded
  with
  | None -> Error (Invalid_service_call { service = caller; ref; message = "target service not found" })
```

So the requirement is that **the selection is closed under the call graph**, and a
call whose target is outside the selection is reported as a missing target rather
than an out-of-scope one.

## The four things this conflates

The user's framing, answered against the code:

1. **A service being a valid referenced dependency in the workspace.** The call is
   declared in the caller's `sol.toml` and names `domain/name`. Validity is never
   checked against the workspace inventory — only against the selection.
2. **A service being selected for this deployment.** This is what `Unit_named`
   gives you: exactly the unit named.
3. **Whether dependencies must already exist or be healthy at the target.**
   **No.** The plan never queries the cluster for a call target. It needs only the
   target's *manifest metadata* to compute the caller's environment
   (`call_env_var`, `service_url ~domain ~k8s_name`). A caller deployed alone
   against an already-running callee would compute a correct URL — which is why
   requiring the callee to be *selected* is strictly stronger than the plan's own
   information requirement.
4. **Whether `--scope` should widen transitively or preserve the requested
   boundary.** Today it does neither: it preserves the boundary *and* requires the
   boundary to be closed. That is a third behaviour, and the one that fails.

## The consequence for this workspace

**There is currently no route that deploys all intended services.**

| Route | Blocked by |
|---|---|
| Whole workspace (`sol deploy` with no `--scope`) | **FND-0012** — a target-level `omit` does not exempt a unit from the profile preflight, so the unqualified TypeScript units block the whole deploy. |
| Scoped, per unit (`--scope payments/charge_svc`) | **This finding** — the unit's call graph leaves the selected scope. |
| Scoped, per domain (`--scope payments`) | Still leaves the call graph: `charge_svc` calls into `checkout`. |

`checkout_svc` deploys only because it calls nothing. This is not a corner of the
workspace: it is every service except the leaves.

The run therefore cannot reach the matrix rows that need `charge_svc` (payment
processing) or the notification chain as a whole, no matter how the deployment is
invoked. That is a qualification-blocking consequence, not just an inconvenience.

## The decision (not taken here)

Four ways out, with materially different meanings:

1. **Resolve call targets from the workspace inventory, not the selection.** A unit
   can be deployed alone against an already-deployed callee; the boundary stays
   exactly what the operator asked for, and the plan's actual information need
   (manifest metadata) is satisfied. Closest to "deploy this one service".
2. **Widen transitively.** Include the callees, and their callees, in the
   release. Unblocks everything, but changes what a *release* is — and therefore
   the release identity that DEC-018 restores.
3. **Keep the closed-world requirement and fix only the diagnosis.** Report
   "not in the selected scope: add `checkout/checkout_svc`, or use a domain
   scope" and name the units that would close the graph. Cheapest, changes no
   semantics, and unblocks nothing on its own.
4. **Something between 1 and 3**: resolve from the inventory, but fail closed if
   the callee neither exists in the workspace nor is selected — so a genuine typo
   is still caught.

My own reading, offered as input rather than a decision: **1 or 4**, because the
plan's requirement is metadata and not liveness, and because a release boundary
that silently grows is harder to reason about than one that stays where the
operator put it. But 2 and 3 are defensible, and this is exactly the kind of
question FND-0002 turned out to be — so it should be recorded as a `DEC` before
anyone implements it.

## What would make this qualified

A single documented command deploys `payments/charge_svc` while `checkout_svc` is
already running, and the deployed pod resolves its callee's address — with the
outcome recorded either way (deployed, or refused with a message that names the
scope rather than the existence of the target).

## Sources

- Live: Run 8, `deploy-20260920T213441Z-547990`, revision `d8d8c876`, target
  `qual/aws/us-east-1`.
- `cli/sol/lib/sol_cli_deployment_scope.ml:136-169` (selection)
- `cli/sol/lib/sol_cli_deployment_plan.ml:806-834` (`lookup_call`)
- `internal/pipeline/audits/findings/FND-0012-omit-does-not-exempt-from-profile-preflight.md`
