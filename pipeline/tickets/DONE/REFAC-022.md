---
id: REFAC-022
type: refactor
severity: low
branch: REFAC-022/centralise-check-tool
worktree: /home/lbendtly/Code/sun-REFAC-022-centralise-check-tool
source: codebase simplification review 2026-06-15
---

Centralise `check_tool` — defined identically in `cmd_dev.ml` and `cmd_cloud.ml`

**Depends on:** None.

**Description:**

Two CLI command files each define the same 5-line helper:

```ocaml
(* cmd_dev.ml lines 6–11 *)
let check_tool name install_url =
  if not (cmd_ok (Printf.sprintf "which %s >/dev/null 2>&1" name)) then begin
    Printf.eprintf "error: '%s' not found in PATH.\n" name;
    Printf.eprintf "Install: %s\n" install_url;
    exit 1
  end

(* cmd_cloud.ml lines 9–14 — identical *)
let check_tool name install_url =
  if not (cmd_ok (Printf.sprintf "which %s >/dev/null 2>&1" name)) then begin
    Printf.eprintf "error: '%s' not found in PATH.\n" name;
    Printf.eprintf "Install: %s\n" install_url;
    exit 1
  end
```

Both also define a local `cmd_ok` alias for `Sun_cli_shell.run_cmd_ok ~echo:false`. That alias should also be removed once `check_tool` lives in the shared module.

**Remediation:**

1. Add to `cli/sun/lib/sun_cli_shell.ml`:
   ```ocaml
   let check_tool name install_url =
     if not (run_cmd_ok ~echo:false (Printf.sprintf "which %s >/dev/null 2>&1" name)) then begin
       Printf.eprintf "error: '%s' not found in PATH.\n" name;
       Printf.eprintf "Install: %s\n" install_url;
       exit 1
     end
   ```
2. Delete `check_tool` and the local `cmd_ok` alias from `cmd_dev.ml` and `cmd_cloud.ml`.
3. Replace all call sites with `Sun_cli_shell.check_tool`.

**Acceptance criteria:**

- `grep -rn "let check_tool" cli/sun/bin/` returns zero hits.
- `dune build` passes.
- `sun dev up` and `sun cloud` still bail with the correct error message when required tools are missing.

## Review — automated checks passed
check_tool() centralised in Sun_cli_shell; two local definitions removed; build clean; zero let check_tool hits in bin/
