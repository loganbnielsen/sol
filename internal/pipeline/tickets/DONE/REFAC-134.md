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

## Completion notes

**Premise verified (2026-09-27):** no `sol_cli_fs.ml`; `rg -n --glob '*.ml' 'Sys\.command|Unix\.(system|open_process|create_process)' cli` listed the spawns named above plus ~45 test-helper `mkdir -p`/`rm -rf` shell-outs, and `try Sys.remove … with _ -> ()` appeared in eight modules.

Built on REFAC-133 and REFAC-135 (the scaffold's raising `mkdir_p` was REFAC-133's named leftover, and a cleanup failure is reported through REFAC-135's `Sol_cli_report`).

- **`Sol_cli_fs`** (`cli/lib/base`): `remove_if_present` (absent is `Ok`; a permission failure is an `Error`), `remove_reporting` (for a `finally` with nothing to return to: warns instead of swallowing), `remove_tree`, `mkdir_p` (the scaffold's race-aware version, returning results), `write_atomic` (rename into place; with `~perm`, exactly that mode), `with_temp_file`, `copy_tree`.
- **One runner.** `Sol_cli_process.spawn`/`pid`/`stop` for a process Sol starts and does not wait for, with the same env merge as `run`. Converted: `sol up`'s build context (`rm -rf` + an `rsync` command string → `remove_tree` + `copy_tree`), `sol local run`'s service processes and its shell `dune build`, `sol local infra up`'s `sleep 2` (`Unix.sleepf`), `sol open`'s `xdg-open`, and the two temporary port-forwards.
- **Two copies of one feature became one.** `sol migrate`'s Postgres forward and `sol deploy`'s Loki event push each hand-rolled "spawn kubectl port-forward, stop it at exit, poll the port with the same five errno cases". Both now use `Sol_cli_kubectl.temporary_port_forward`, which returns *not started / not ready / readiness check failed*. Each caller keeps its own messages and policy (Postgres fails only when the forward cannot start; the Loki push never fails the deploy).
- **Temporary files.** Three identical `with_temp_json`s (release store, deployment store, boundary lease), helm values, the deployed-groups record, secrets, manifests, Loki's credential file, the migration Job/ConfigMap and Dockerfile, the provisioner kubeconfigs and plan files: all through `with_temp_file` or `remove_reporting`. Found along the way: **the workspace substrate's temporary manifests were never removed at all.** `Sol_cli_manifest.write_tmp` is gone; `emit_to_dir` and the GitOps release bundle return their write errors instead of raising them.
- **The run log** is diagnostics and, per INFRA-033, must not abort a command; its directory and file writes now warn instead of raising. **The Terraform workdir**'s preparation lost its catch-all `try` for per-step results.
- **Deliberately left:** `Sol_cli_supervised` spawns and reaps Terraform itself, owns its session and signals, and keeps its own write-then-rename record writer. It is the named exception in the guard, and its failures are caught at the top of its own process.
- **Equivalence of the build-context copy:** `copy_tree` and `rsync -a --copy-links --exclude=_build --exclude=.git` run on `examples/pluto`: the same 83 paths, modes and types, and `diff -r` finds no difference.
- **Guard:** `internal/ci/check_single_runner.sh` (no spawn in `cli/` bin/lib/test outside `Sol_cli_process` and the supervisor; no `Sys.remove`/`Unix.unlink`/`Unix.rmdir` in bin/lib outside `Sol_cli_fs`) + `test_single_runner.sh` (four cases). REFAC-133's allow-list entry for `sol_cli_scaffold.ml` is removed, since the scaffold no longer raises.
- **Tests:** new `cli/test/test_fs.ml` (absent/present/unremovable, a tree with a symlink not followed, atomic writes leaving no temp file, `with_temp_file` cleanup, `copy_tree` excludes/modes/symlinks, `spawn` and a missing program). Every test that shelled out -- ~45 `mkdir -p`/`rm -rf` helpers across ten files, `chmod -R` in the workdir test, the scaffold's `dune build`s, the `sleep`/`flock` stand-ins -- uses `Sol_cli_fs`/`Sol_cli_process`. The scaffold's `mkdir_p` regression tests now assert on `Sol_cli_fs.mkdir_p`'s errors. `dune test cli/ --force`: 0 failures; format clean.
- **Demo/example:** not applicable (internal; output unchanged). **Language parity:** no impact.
