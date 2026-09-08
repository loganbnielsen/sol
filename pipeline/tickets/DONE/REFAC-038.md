---
id: REFAC-038
type: refactor
severity: low
branch: REFAC-038/use-scaffold-mkdir
worktree: /home/lbendtly/Code/sun-REFAC-038-use-scaffold-mkdir
source: codebase simplification review 2026-06-15
---

Replace inline `mkdir -p` shells in cmd_up and cmd_dev with `Sun_cli_scaffold.mkdir_p`

**Depends on:** REFAC-021.

**Description:**

`sun_cli_scaffold.ml` already defines:

```ocaml
(* sun_cli_scaffold.ml:22–23 *)
let mkdir_p dir =
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote dir)))
```

Despite this, `cmd_up.ml` and `cmd_dev.ml` each inline the exact same one-liner inside `ensure_state_dir`:

```ocaml
(* cmd_up.ml:17 *)
ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote state_dir)))

(* cmd_dev.ml:35 *)
ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote state_dir)))
```

REFAC-021 will extract `ensure_state_dir` into `Sun_cli_State.ensure`. This ticket ensures that extracted function uses `Sun_cli_Scaffold.mkdir_p` rather than re-inlining the pattern.

Note: REFAC-021 creates `sun_cli_state.ml` first; this ticket adjusts the implementation of `Sun_cli_State.ensure` to call `Sun_cli_Scaffold.mkdir_p` rather than shelling out directly.

**Remediation:**

When implementing REFAC-021's `sun_cli_state.ml`:
```ocaml
let ensure () = Sun_cli_scaffold.mkdir_p dir
```

If REFAC-021 is already merged before this ticket is picked up: find `ensure_state_dir` in `sun_cli_state.ml` and replace the inline `Sys.command` with `Sun_cli_scaffold.mkdir_p dir`. Add `sun_cli_scaffold` to `sun_cli_state`'s dependencies in the dune file if needed.

**Acceptance criteria:**

- `grep -rn "mkdir -p.*state_dir\|Sys.command.*mkdir" cli/sun/` returns zero hits.
- `dune build` passes.
- `sun up` and `sun dev up` still create the state directory on first run.

## Review — automated checks passed
sun_cli_state.ml uses Sun_cli_scaffold.mkdir_p, mli exported, build passes
