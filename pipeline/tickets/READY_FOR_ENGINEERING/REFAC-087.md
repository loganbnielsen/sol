---
id: REFAC-087
type: refactor
severity: low
source: split from REFAC-086, 2026-09-11 — the architectural half of the local/target work
---

**Depends on:** None.

**Related:** REFAC-086 (which landed the alias removal and the destination guard), FEAT-064 (scope), REFAC-083 (the reservation), DEC-016, DEC-020.

Align the naming around `local`, and single-source each capability's semantic core across the two surfaces.

## Work

**1. Rename `cmd_dev.ml` → `cmd_local.ml`.** The file implements the `local` group (`Cmd.group (Cmd.info "local" ~doc:"Manage the local cluster (k3d) and its substrate")`) and has not been named for what it contains since REFAC-083 renamed the command. Update the module reference in `main.ml` and the module list in `cli/sol/bin/dune`. Cosmetic on its own, but naming carries weight in a codebase actively keeping `dev`, `local`, `target`, `environment` and `destination` distinct.

**2. Share the capability core, not the CLI registration.** `sol local status` and `sol status --target <name>` are *not* the same product operation with a different destination: the local surface may grow substrate state (k3d, Redpanda, Postgres, Grafana health) that the remote one has no reason to grow. So the shared thing is the workload operation after destination and scope are resolved:

```ocaml
status : destination -> scope -> status_result
```

with each surface wrapping it. Forcing the Cmdliner definitions to stay structurally identical would couple two UX surfaces that should be free to diverge, which is the opposite of what this split is for.

What must agree is the **shared core's inputs** — destination and scope. That makes the drift risk "one core with two entry points" instead of "two command definitions that must match", and it puts the test at the seam: given the same `(destination, scope)`, the core behaves identically. For FEAT-064 this means `--scope` belongs to the core and is accepted by both surfaces, while local-only substrate flags do not.

## Acceptance criteria

- The file implementing the `local` group is named for it, with no reference left to the old module name.
- Each capability has one semantic core and two entry points, with a test asserting identical core behaviour for the same `(destination, scope)` — not identical CLI definitions.
- `--scope` is accepted by both surfaces for the same core operation (or, where a scope cannot be projected for one of them, the reason is recorded rather than silently omitted).
- Local-only capabilities (substrate health, cluster lifecycle) are not forced onto the target surface by the sharing.

## Notes

Split from REFAC-086 so the alias removal and the destination guard could land without waiting on a change to two command surfaces. The naming decision itself is settled and recorded in REFAC-086; this ticket is the execution of it.
