---
id: INFRA-053
type: bug
severity: high
title: Resolve call targets from the workspace inventory, not the deployment selection
source: audit finding FND-0016 — DEC-036
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0016-scoped-deploy-requires-a-closed-call-graph.md`
**Decision:** `DEC-036`

## The defect

A scoped deploy requires its call graph to be inside the scope:

```console
$ sol deploy qual/aws/us-east-1 --scope payments/charge_svc --image-ref …
error: service "charge_svc" calls "checkout/checkout_svc": target service not found
```

`checkout/checkout_svc` exists, is deployed and is healthy. `Unit_named` selects
exactly one unit (`sol_cli_deployment_scope.ml:148-158`) and `lookup_call` resolves
references against that selection (`sol_cli_deployment_plan.ml:806-834`), so
selection and dependency resolution are conflated.

With FND-0012, this leaves the workspace with no route that deploys all its services.

## The fix (per DEC-036)

1. **Resolve call targets against the workspace inventory**, not the selected units.
   The plan needs the callee's manifest metadata (`domain`, `name`, derived URL) —
   never its liveness, and never its presence in this release.
2. **Keep failing closed** when the referenced domain/unit does not exist in the
   workspace, with a message naming the reference and what the workspace contains.
3. **Do not widen the deployment scope.** The selection stays exactly what
   `--scope` asked for; the release record's workload list must show that.

The inventory is already discovered before the plan is built, so this is a matter
of resolving against the full set rather than the selected subset — not a new
discovery pass. Check what `plan_of_services` is handed today and thread the
inventory alongside the selection rather than replacing it (the plan's `services`
field is the deployment boundary and other consumers depend on it).

## Acceptance criteria

1. A scoped deploy of a unit whose call graph leaves the scope **succeeds** when the
   referenced units exist in the workspace, and the caller's environment carries the
   callee's URL (an `env` entry derived from the callee's manifest).
2. A reference to a **nonexistent or misspelled** domain/unit still **fails**, and
   the message names the reference and the workspace's available units.
3. The deployed set is exactly the requested scope — no transitive widening,
   demonstrable from the release record's workload list.
4. Regression coverage for both (1) and (2), as pure tests over the plan builder
   rather than live clusters.
5. Live: `sol deploy --scope payments/charge_svc` succeeds against the preserved
   Run 8 target, with `checkout_svc` already deployed.

## Out of scope

Whether a callee must be *running* — DEC-036 leaves that to a health/preflight
concern. And the whole-workspace preflight problem, which is FND-0012/`INFRA-049`.

## Landed (2026-09-20)

DEC-036 implemented: call targets resolve from the workspace inventory; specs still come from the selection, so nothing widens. Live-retested: `--scope payments/charge_svc` succeeded with `checkout_svc` deployed and unchanged.

Merged in #393; live-retested against the preserved Run 8 target. See
`internal/qualification/records/2026-09-20-run8-aws.md`.
