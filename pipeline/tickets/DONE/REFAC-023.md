---
id: REFAC-023
type: refactor
severity: high
source: codebase simplification review 2026-06-15
branch: REFAC-023/extract-port-forward
worktree: /home/lbendtly/Code/sun-REFAC-023-extract-port-forward
---

Extract port-forward logic to `sun_cli_port_forward.ml` — currently split across two 500+ line commands

**Depends on:** REFAC-021.

**Description:**

`cmd_up.ml` and `cmd_dev.ml` both manage `kubectl port-forward` processes via a self-restart shell script + PID file convention. The implementations diverge:

**`cmd_up.ml`** (lines 41–240, ~200 lines):
- `port_forward_running` — reads PID file, checks `ps`, inspects args
- `start_port_forward` — writes shell script, starts background process
- `check_port_forward_liveness` — nc-probes the local port
- `log_file`, `script_file` helpers
- `detect_stale_port_forward` — parses `ps aux` output to find conflicting processes

**`cmd_dev.ml`** (lines 37–91, ~55 lines):
- `pid_file`, `log_file`, `script_file` — same conventions
- `start_port_forward` — same shell-script pattern but accepts a record instead of named args
- `stop_port_forwards` — kills all sun-pf PIDs

Neither file reuses the other's code. Adding a new command that needs port-forwards (e.g., `sun run` or `sun proxy`) would require a third copy.

REFAC-021 moves the state directory helpers out first; this ticket builds on that.

**Remediation:**

1. Create `cli/sun/lib/sun_cli_port_forward.ml`:
   ```ocaml
   type spec = {
     name         : string;
     namespace    : string;
     target       : string;   (* "svc/<name>" or "pod/<name>" *)
     local_port   : int;
     remote_port  : int;
   }

   val is_running   : string -> bool
   val start        : spec -> unit
   val stop_all     : unit -> unit
   val check_alive  : name:string -> local_port:int -> bool
   val detect_stale : local_port:int -> namespace:string -> target:string -> bool
   ```

   Move the implementations from `cmd_up.ml` (the fuller version) here, adjusted to use `Sun_cli_state.*` for path helpers.

2. In `cmd_dev.ml`: delete `start_port_forward`, `stop_port_forwards`, `pid_file`, `log_file`, `script_file`. Replace with calls to `Sun_cli_port_forward.*`.

3. In `cmd_up.ml`: delete `port_forward_running`, `start_port_forward`, `check_port_forward_liveness`, `log_file`, `script_file`, `detect_stale_port_forward`. Replace with calls to `Sun_cli_port_forward.*`.

**Acceptance criteria:**

- `grep -rn "let start_port_forward\|let stop_port_forward\|let port_forward_running" cli/sun/bin/` returns zero hits.
- `dune build` passes.
- `sun up` and `sun dev up` port-forward behaviour is unchanged (PID files in same location, same restart-loop script).

## Review — automated checks passed
Port-forward logic correctly extracted to sun_cli_port_forward.ml; all acceptance criteria met, build clean, no old function names remain in bin/
