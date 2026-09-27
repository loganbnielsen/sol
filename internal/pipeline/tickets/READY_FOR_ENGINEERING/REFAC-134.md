---
id: REFAC-134
type: refactor
severity: medium
title: Every subprocess goes through Sol_cli_process, and filesystem chores go through one Sol_cli_fs
source: pattern audit of the REFAC-104..130 series (2026-09-26); REFAC-124 made one runner but did not route every spawn through it
premise: "test -f cli/lib/base/sol_cli_fs.ml"
---

**Depends on:** None.

## The problem

REFAC-124 left one process runner, with timeouts and SEC-010 redaction. Several spawns bypass it, so they get neither, and a failure is an unreported exit code:

- `cli/lib/deploy/sol_cli_up_execution.ml:64-77`: `Sys.command "rm -rf …"` and an `rsync` command string.
- `cli/bin/cmd_local.ml:534` (`Sys.command "sleep 2"`), `:856-872` (a built command string, then `Unix.create_process_env`).
- `cli/bin/cmd_open.ml` (`xdg-open … &` through `Sys.command`), `cmd_migrate.ml:40`, `cmd_deploy_event.ml:40` (`Unix.create_process_env`).

Filesystem chores are hand-rolled the same way everywhere:

- `try Sys.remove path with _ -> ()` in `sol_cli_helm`, `sol_cli_manifest` (×2), `sol_cli_secret`, `sol_cli_loki` (×2), `sol_cli_local_infra`, `sol_cli_run_log` -- the catch-all also hides a permission error.
- temp-file-then-rename written out per module.
- in `cli/test`, 20 files each define their own `mkdir -p` / `rm -rf` helper through `Sys.command`.

## Remediation

- A `Sol_cli_fs` in `cli/lib/base`: `remove_if_present` (absent is `Ok ()`, other errors are `Error`), `remove_tree`, `mkdir_p`, `with_temp_file`, `write_atomic`, `copy_tree` (for the build-context copy). OCaml's `Sys`/`Unix`/`Filename` only -- no shell.
- Every spawn in `cli/` goes through `Sol_cli_process.run` (or a long-running spawn it exports, for the detached cases such as `xdg-open` and the port-forward wrapper), so redaction and error text are uniform. `sleep 2` becomes `Unix.sleepf`.
- Tests use `Sol_cli_fs` (or one shared test-support helper built on it), not shell.
- A guard: no `Sys.command`, `Unix.system`, `Unix.open_process*` or `Unix.create_process*` in `cli/` outside `Sol_cli_process` (and the supervisor, which is named), with a mutation test.

## Acceptance criteria

- `rg -n --glob '*.ml' 'Sys\.command|Unix\.(system|open_process|create_process)' cli` lists only `sol_cli_process.ml` and the named exceptions.
- `rg -n 'with _ -> \(\)' cli/lib` around `Sys.remove` prints nothing.
- Unit tests for `Sol_cli_fs` (absent vs. present vs. unremovable; atomic write leaves no temp file on failure).
- The guard runs in CI; a planted `Sys.command` fails it.
- Demo/example: not applicable (internal). Language parity: no impact.
