---
id: REFAC-021
type: refactor
severity: high
source: codebase simplification review 2026-06-15
branch: REFAC-021/state-dir-module
worktree: /home/lbendtly/Code/sun-REFAC-021-state-dir-module
---

Extract `state_dir` / `pid_file` / `ensure_state_dir` to a shared CLI module

**Depends on:** None.

**Description:**

`cmd_up.ml` and `cmd_dev.ml` each contain identical blocks for locating the Sun state directory, deriving PID file paths, and ensuring the directory exists. The duplication is line-for-line:

```ocaml
(* cmd_up.ml lines 7–19  /  cmd_dev.ml lines 20–37 — word-for-word identical *)
let state_dir =
  let default () =
    match Sys.getenv_opt "HOME" with
    | Some h -> Filename.concat h ".local/share/sun"
    | None   -> Filename.concat (Sys.getcwd ()) ".sun"
  in
  match Sys.getenv_opt "XDG_DATA_HOME" with
  | Some d -> Filename.concat d "sun"
  | None   -> default ()

let ensure_state_dir () =
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote state_dir)))

let pid_file name = Printf.sprintf "%s/pf-%s.pid" state_dir name
```

Both commands also define `log_file` and `script_file` using the same temp-path conventions. If the XDG spec ever needs to change, or if a third command needs port-forwards, there's no shared place to make the change.

**Remediation:**

1. Create `cli/sun/lib/sun_cli_state.ml`:
   ```ocaml
   let dir =
     let default () =
       match Sys.getenv_opt "HOME" with
       | Some h -> Filename.concat h ".local/share/sun"
       | None   -> Filename.concat (Sys.getcwd ()) ".sun"
     in
     match Sys.getenv_opt "XDG_DATA_HOME" with
     | Some d -> Filename.concat d "sun"
     | None   -> default ()

   let ensure () =
     ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote dir)))

   let pid_file name   = Printf.sprintf "%s/pf-%s.pid" dir name
   let log_file name   = Printf.sprintf "/tmp/sun-pf-%s.log" name
   let script_file name = Printf.sprintf "/tmp/sun-pf-%s.sh" name
   ```

2. Add `sun_cli_state` to the `(modules ...)` stanza in the `cli/sun/lib/` dune file.

3. In `cmd_up.ml` and `cmd_dev.ml`, delete the local `state_dir`, `ensure_state_dir`, `pid_file`, `log_file`, and `script_file` definitions. Replace all references with `Sun_cli_state.*`.

**Acceptance criteria:**

- `grep -rn "XDG_DATA_HOME\|\.local/share/sun" cli/sun/bin/` returns zero hits.
- `grep -rn "let pid_file\|let log_file\|let script_file" cli/sun/bin/` returns zero hits.
- `dune build` passes.
- `sun up` and `sun dev up` still write PID files to the same path as before.

## Review — automated checks passed
REFAC-021 correctly extracts state_dir/ensure/pid_file/log_file/script_file into Sun_cli_state; build passes, diff scope is clean, conventions are met
