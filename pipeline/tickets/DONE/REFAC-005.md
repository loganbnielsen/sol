---
id: REFAC-005
type: refactor
severity: medium
source: codebase simplification review 2026-06-13
branch: REFAC-005/consolidate-port-forward
worktree: ../sun-REFAC-005-consolidate-port-forward
---

Consolidate duplicated port-forward management from `cmd_dev.ml` and `cmd_up.ml` into a shared `Sun_cli_port_forward` module

**Depends on:** None.

**Description:**

Both `cli/sun/bin/cmd_dev.ml` and `cli/sun/bin/cmd_up.ml` implement port-forward start/stop independently, using divergent interfaces and partially overlapping logic:

- Both generate `/tmp/sun-pf-*.sh` wrapper scripts and `/tmp/sun-pf-*.log` files.
- Both track PIDs in `.sun/pf-*.pid` files.
- `cmd_dev.ml` defines a `pf_spec` record type and `start_port_forward`/`stop_port_forwards` functions (~37 lines, lines 61-97).
- `cmd_up.ml` defines a different `start_port_forward` with individual parameters instead of a record (~70 lines), plus a more elaborate liveness check that reads `/proc/<pid>/cmdline` to verify the wrapper script name (~30 additional lines, lines 65-133).

The liveness check improvement in `cmd_up.ml` was never backported to `cmd_dev.ml`. Any future change to the PID-file path convention or log rotation must be applied twice.

**Remediation:**

1. Create `cli/sun/lib/sun_cli_port_forward.ml` with:
   ```ocaml
   type spec = {
     name      : string;
     namespace : string;
     service   : string;
     local_port  : int;
     remote_port : int;
   }

   val start  : work_dir:string -> spec -> unit
   val stop   : work_dir:string -> spec -> unit
   val stop_all : work_dir:string -> spec list -> unit
   val is_alive : work_dir:string -> spec -> bool
   ```
   Implement using the stronger liveness check from `cmd_up.ml` (`/proc/<pid>/cmdline` verification).
2. Expose via the `sun_cli` library.
3. Replace the local implementations in `cmd_dev.ml` and `cmd_up.ml` with calls to `Sun_cli_port_forward`.

**Acceptance criteria:**

- `cmd_dev.ml` and `cmd_up.ml` contain no local `start_port_forward`/`stop_port_forward` definitions.
- PID-file and script-file naming conventions are identical between the two commands.
- `sun dev up` and `sun up` both start and stop port-forwards correctly (verify manually or via existing integration coverage).
- `dune build` passes.

## Review — automated checks passed
Sun_cli_port_forward module created, build passes, callers updated with no local port-forward definitions remaining, naming conventions unified, wrapped false, all paths Filename.quoted
