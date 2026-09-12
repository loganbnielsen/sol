---
id: REFAC-088
type: refactor
severity: low
source: split from REFAC-087, 2026-09-12 — the capability-core half, gated on the destination abstraction
---

**Depends on:** FEAT-063.

**Related:** REFAC-087 (the naming half, split out so it could land), REFAC-086, FEAT-064 (scope), REFAC-083, DEC-016, DEC-020.

Single-source each capability's semantic core across the two surfaces, with the destination resolved.

## Work

`sol local status` and `sol status --target <name>` are *not* the same product operation with a different destination: the local surface may grow substrate state (k3d, Redpanda, Postgres, Grafana health) that the remote one has no reason to grow. So the shared thing is the workload operation after destination and scope are resolved:

```ocaml
status : destination -> scope -> status_result
```

with each surface wrapping it. Forcing the Cmdliner definitions to stay structurally identical would couple two UX surfaces that should be free to diverge, which is the opposite of what this split is for.

What must agree is the **shared core's inputs** — destination and scope. That makes the drift risk "one core with two entry points" instead of "two command definitions that must match", and it puts the test at the seam: given the same `(destination, scope)`, the core behaves identically. `--scope` belongs to the core and is accepted by both surfaces, while local-only substrate flags do not.

**Gated on FEAT-063.** The core's destination parameter *is* the required-destination threading FEAT-063 introduces. Attempting this before it lands would mean inventing a second destination concept — which is exactly the word REFAC-083 reserved.

## Acceptance criteria

- Each capability has one semantic core and two entry points, with a test asserting identical core behaviour for the same `(destination, scope)` — not identical CLI definitions.
- `--scope` is accepted by both surfaces for the same core operation (or, where a scope cannot be projected for one of them, the reason is recorded rather than silently omitted).
- Local-only capabilities (substrate health, cluster lifecycle) are not forced onto the target surface by the sharing.
