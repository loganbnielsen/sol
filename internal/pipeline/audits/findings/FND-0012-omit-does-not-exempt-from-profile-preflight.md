# FND-0012 — A target-level `omit` does not exempt a unit from the profile preflight

- **Classification:** `VERIFIED_DEFECT` (remedy depends on an unestablished intent —
  see "Not yet established")
- **State:** `OPEN`
- **First identified:** 2026-09-20, AWS Run 8 (second observation; first
  2026-09-20 during the Run 8 preflight)
- **Derived ticket:** `INFRA-049`
- **Evidence class:** `BEHAVIORAL` (preflight invocations on the landed target)

## The observation

`examples/pluto/sol/qual/aws/us-east-1.yml` omits the workspace's two TypeScript
services, in the same way `sol/dev/aws/us-east-1.yml` omits `charge_svc` and
`notify_worker`:

```yaml
services:
  order_svc:
    omit: true

  fulfillment_worker:
    omit: true
```

The profile preflight still reports them:

```text
error: this target selects profile production-single-region/v1, and preflight
found 2 unmet guarantee(s). Nothing was changed.
  - qualified version set is not established [application]: service "order_svc"
    declares language typescript, which production-single-region/v1 does not
    qualify; the first profile is OCaml-only (DEC-026 §2)
  - immutable artifact identity is not established [application]: every workload
    must deploy an immutable reference; ...
```

`omit` is a real config key (`Sol_cli_config`, `Target_*`/`omit` handling), not a
typo. `--scope` is what actually narrows the preflight's view: with
`--scope checkout/checkout_svc` the two unmet guarantees above become one (the
alert receiver, since fixed), and the TypeScript one disappears.

## The consequence

The second unmet guarantee is the consequential half, and it is a direct
consequence of the first: because the omitted units are still in scope, they have
no `--image-ref`, so the profile also reports every workload as having a mutable
artifact identity. Deploying the workspace's OCaml services without `--scope` is
therefore impossible, and the workspace cannot be deployed wholesale at all while
it declares a TypeScript unit.

Whether *that* is intended is a separate matter — `sol.yml` says the preflight
reporting TypeScript "is the honest state until the TS parity triggers fire"
(DEC-026 §2). What is not established is whether a target's `omit` is supposed to
exempt a unit from that report. This finding records the observable; it does not
claim the remedy.

## Observations

1. **2026-09-20, Run 8 preflight:** `sol deploy qual/aws/us-east-1 --dry-run
   --image-tag probe` reported `order_svc` (TypeScript) plus the mutable-tag
   error; `--scope checkout/checkout_svc` with a digest removed the TypeScript
   error.
2. **2026-09-20, Run 8 step 6:** the same target, deployed with three
   `--image-ref` digests and no `--scope`, reported the TypeScript error *and*
   "immutable artifact identity is not established" — the omitted units being in
   scope is what produced the second error too.

## Not yet established

- Whether `omit` is meant to remove a unit from the profile preflight, or only
  from what gets deployed. The two readings imply opposite fixes (make `omit`
  exempt the preflight, or stop implying that it does), and the choice is a
  contract decision, not a code detail.
- Whether the intended use of the pluto workspace with the production profile is
  always `--scope`-ed deployment. If it is, this is a documentation gap in the
  workspace's own `sol.yml` comment and the qualification procedure, not a defect
  in `omit`.

Deliberately not investigated during Run 8.

## What would make this qualified

Whichever way the intent resolves, a target that omits a unit and a target that
does not must behave distinguishably and explainably in the profile preflight,
and the qualification procedure must say which invocation
(`--scope`-ed or not) a run is expected to use.
