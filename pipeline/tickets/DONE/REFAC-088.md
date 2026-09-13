---
id: REFAC-088
type: refactor
severity: low
source: split from REFAC-087, 2026-09-12 — the capability-core half, gated on the destination abstraction
---

**Depends on:** FEAT-063.

**Premise checked 2026-09-13:** the shared core already exists — `Cmd_status.run ~ctx scope …`
is called by both `cmd` and `local_cmd`, and the substrate surface was moved to
`sol local infra` in FEAT-063. What was missing was this ticket's own AC: the
seam had no test, and the seam lived in `bin/` where tests cannot reach it.

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

## Completion notes

Landed 2026-09-13.

**FEAT-063 delivered the substance, this PR delivered the evidence.** The core
was already single-sourced: `Cmd_status.run ~ctx scope …`, `Cmd_logs.run ~ctx …`,
`Cmd_rollback.run ~ctx …`, `Cmd_migrate.run_apply ~ctx …` are each called by
both entry points, and the surfaces differ only in how `ctx` is produced. So the
work here was not to re-do the sharing but to make it *checkable*, which is what
the acceptance criterion actually asks for.

**The seam moved into the library.** The resolution policy is now
`Sol_cli_destination.resolve ~command ~local ~target`, in `sol_cli` rather than
`bin/`, because a policy only reachable through the command modules cannot be
tested. `cli/sol/bin/cmd_destination.ml` shrank to the Cmdliner-facing shell it
should always have been: the flag, the exit-on-error, and the `local`/`top`
helpers the command modules use.

**The test is the acceptance criterion.** `cli/sol/test/test_destination.ml`
pins the policy — eight cases:

- the local entry point resolves to the literal local cluster;
- a local invocation stays local even if a target is somehow also present;
- a top-level command with no target fails closed, and its message names
  `--target` and the *command-specific* `sol local <command>` spelling
  (`sol local rollback` for rollback, not `sol local status`);
- a named target supplies its destination from its `kube_context`;
- a target without a `kube_context` fails closed saying what to add;
- a target pointed at the reserved local cluster is refused and redirected to
  the local form;
- resolution is deterministic in its inputs.

**Acceptance criteria.**

- *One semantic core and two entry points, with a test at the seam* — met. The
  test is at `(destination, scope)`'s destination half; the scope half is
  FEAT-064/FEAT-065 (`Sol_cli_deployment_scope` + the shared selection bridge),
  already landed.
- *`--scope` accepted by both surfaces* — met (FEAT-065): the local mirrors and
  the top-level forms wire the same `scope_arg`.
- *Local-only capabilities not forced onto the target surface* — met, and
  recorded here rather than left implicit: the substrate lifecycle is
  `sol local infra up|down|status`, which the target surface does not expose at
  all. The sharing therefore hooked up workload operations only.

**Deliberately not done:** the Cmdliner definitions were *not* forced to be
structurally identical. The ticket's own framing is that the two UX surfaces
should stay free to diverge, and they do — the local forms carry no `--target`,
and `sol local` carries substrate commands the target surface has no equivalent
for. What agrees is the core's inputs, which is what is tested.
