---
id: REFAC-086
type: refactor
severity: low
source: local/target taxonomy discussion, 2026-09-11 — the naming and the seams, not the behaviour
---

**Depends on:** None.

**Related:** DEC-016 (`SOL_ENV`), DEC-020 (destinations), FEAT-061 / FEAT-064 (scope), REFAC-083 (the reservation).

Settle `local` as a built-in execution mode: retire the stale `dev` alias, close the destination hole the reservation leaves open, and align the naming around it.

## The invariant

> **Local and configured targets may share execution machinery, but they are different product concepts.**

```text
configured target                     local
  prod / staging / …                    Sol-owned ephemeral substrate
  user/project config                   built-in destination
  has credentials                       no target record, no credentials
  has SOL_ENV                           no SOL_ENV (DEC-016)
  selected with --target                selected by command namespace: sol local …
```

**Why not a synthetic `local` target for symmetry.** Remote environments are things the user configures and names; local is something Sol provides. A synthetic target would blur that, and it would also collide with the reservation: `sol local status` and `sol status --target local` would be two concepts wearing one word. The reservation (`reserved_env_name = "local"`, `sol_cli_config.ml:709`) exists precisely to prevent that.

## Work

**1. Remove the stale `dev` alias.** `Sol_cli_secret.ml:18` still reads `| "local" | "dev" -> Ok Local`. `dev` was retired as user vocabulary when `sol dev up` became `sol local up` (REFAC-083); leaving it in a config vocabulary means the retired word reappears later in examples, error messages and migrations. Delete it, and check config fixtures, tests and `examples/` first — if something depends on it, that dependency is the finding, not a reason to keep the alias.

**2. Rename `cmd_dev.ml` → `cmd_local.ml`.** The file implements the `local` group (`Cmd.group (Cmd.info "local" ~doc:"Manage the local cluster (k3d) and its substrate")` at the bottom) and has not been named for what it contains since REFAC-083. Cosmetic, done whenever someone is next in there — but naming carries meaning in a codebase actively keeping `dev`, `local`, `target`, `environment` and `destination` distinct.

**3. Fail closed when a configured target points at the local substrate.** The reservation covers the *name* `local`, not the *destination*: nothing stops a target being configured with `kube_context = "k3d-sol-local"` — the literal in `Sol_cli_kube_destination.local` — which gives target semantics (credentials, `SOL_ENV`, target selection) to the ephemeral cluster. That is the same ambiguity the reservation prevents, one level down. Note the existing same-cluster check cannot see it: `validate_no_same_cluster` compares environments to each other, and local is not an environment. Decide between refusing it and warning loudly; refusing is consistent with everything else here.

**4. Share the capability core, not the CLI registration.** The two surfaces are *not* the same product operation with a different destination: `sol local status` may grow substrate state (k3d, Redpanda, Postgres, Grafana health) while `sol status --target` stays about workloads. So single-sourcing should happen at the semantic layer —

```ocaml
status : destination -> scope -> status_result
```

— with each surface wrapping it, and structural identity of the Cmdliner definitions is a bug rather than a goal.

What must agree across surfaces is the **shared core's inputs** — destination and scope. So the drift risk moves from "two command definitions that must match" to "one core with two entry points", and the test belongs at the **seam**, not the surface: given `(destination, scope)`, the core behaves identically. For FEAT-064 that means `--scope` belongs to the core (both surfaces accept it), while local-specific substrate flags do not.

## Acceptance criteria

- No `dev` alias for `local` remains anywhere in config parsing, and no fixture or example depends on one.
- `local` is spelled one way across the CLI, config and docs — and remains unavailable as a target name.
- A configured target cannot silently point at the local substrate's cluster; attempting it fails closed (or is documented as a loud warning, with the reason recorded).
- `sol local <capability>` and `sol <capability> --target <name>` share one semantic core, and a test asserts identical core behaviour given the same `(destination, scope)` rather than identical CLI definitions.
- The file that implements the `local` group is named for it.

## Notes

Nothing here changes behaviour the reservation already established; it closes the gaps that were left next to it. Work item 3 is the only one that adds a check rather than removing or renaming something.
