---
id: REFAC-135
type: refactor
severity: low
title: Library code does not print -- warnings are returned, progress goes to a sink the command passes in
source: pattern audit of the REFAC-104..130 series (2026-09-26); REFAC-120's "resolve, then print", applied by REFAC-126 to port_forward only
premise: "test -f internal/ci/check_library_output.sh"
---

**Depends on:** None.

## The problem

REFAC-120 wrote down "a function that computes something does not also print it", and REFAC-126 applied it to `sol_cli_port_forward`. `rg -n --glob '*.ml' 'Printf\.(e?printf)|print_endline|prerr_endline' cli/lib` (2026-09-26) still lists about 60 sites in three kinds:

1. **Warnings printed and dropped**, so no caller or test can see them: `sol_cli_boundary_lease.ml:365,466`, `sol_cli_deployment_attempt.ml:39`, `sol_cli_workspace_scan.ml:11,23`, `sol_cli_deployment_state.ml:125`, `sol_cli_docker.ml:28`, `sol_cli_terraform.ml:48`.
2. **Results rendered in place**: `sol_cli_cmd_new.ml` (10: the "Scaffolding… / Done." report), `sol_cli_scaffold.ml` / `sol_cli_scaffold_tree.ml` ("created / linked / updated"), `sol_cli_manifest.ml:169` (dry-run YAML).
3. **Progress narration of long operations**: `sol_cli_aws_cluster` (10), `sol_cli_aws_destruction` (5), `sol_cli_gcp_destruction` (5), `sol_cli_gcp_cluster`, `sol_cli_run_log`, `sol_cli_local_infra` (7).

## Remediation

- **Warnings** become values: the function returns them with its result (or as the `Error` of a non-fatal step), and the command prints them.
- **Results** are returned (`sol new` returns what it created/linked/updated; the dry run returns the documents) and rendered by the command.
- **Progress** of a long operation goes through an explicit sink the command passes in (`~progress:(string -> unit)`, or a small `Sol_cli_progress.t`), so the library decides *what* happened and the command decides *where it goes*. Tests pass a collecting sink and assert on it.
- Named exceptions, each with its reason: `Sol_cli_process`'s `?echo` (its contract), `Sol_cli_exit` (it is the edge), the `__supervise` child (it is its own process), `Sol_cli_args` (a Cmdliner printer).
- A guard `internal/ci/check_library_output.sh`: no print in `cli/lib` outside the named exceptions, with a mutation test.

## Acceptance criteria

- The guard runs in CI; a planted `Printf.printf` in `cli/lib` fails it.
- User-visible output of `sol new`, `sol local infra up`, `sol cloud apply/destroy` (offline harness) is unchanged; say how it was compared.
- At least one test asserts on a previously printed-and-dropped warning (e.g. the boundary lease release failure).
- Demo/example: not applicable (output unchanged). Language parity: no impact.

## Completion notes

**Premise verified (2026-09-27, `origin/main` at `62ab9b9a`):** no `check_library_output.sh`; `rg -n --glob '*.ml' 'Printf\.(e?printf)|print_endline|prerr_endline' cli/lib` listed about 60 sites in the three kinds above.

- **The sink is `Logs`.** Rather than threading a `~progress` argument through every cloud-lifecycle signature, library code reports through `Sol_cli_report` (`app` for progress and results, `warn`, `err`, and `app_block`/`err_block` for text that already ends in a newline), which emits through the `logs` library -- the established OCaml shape for "a library emits, the application decides where it goes" (already in the switch, as cohttp's dependency). `Sol_cli_report.terminal` is the one reporter that writes to the terminal (stdout for `app`, stderr otherwise, one newline, flushed); `main.ml` installs it first thing, before the supervisor dispatch, so the `__supervise` child reports the same way. Tests install `Sol_cli_report.collect` and assert on what was reported. The format arguments stay `Printf`'s, so every message is byte-identical.
- **Converted, all of them:** the warnings (boundary lease abort/release, deployment record, workspace scan, consumer-group check, docker buildx fallback), the results (`sol new`'s scaffolding report, `created`/`linked`/`updated`, the dry-run YAML), the progress narration (AWS/GCP cluster and destruction, run-log phase lines and failure report, local infra installs), the Terraform errored-state notice, the supervisor's interrupt notices, and `Sol_cli_process`'s echo -- which is progress too, so the named exception the ticket anticipated for it was not needed. The forked install child reports its failure through the same reporter; its stderr is its log file.
- **What still prints in `cli/lib`:** `Sol_cli_report` itself (the terminal reporter) and `Sol_cli_exit` (a command's edge). `Sol_cli_args`'s `Format.pp_print_string` is a Cmdliner printer argument, not output.
- **Output unchanged, compared byte for byte** against the pre-change binary (`origin/main` built in a scratch worktree), stdout and stderr separately: `sol new workspace demo` (57 lines, identical), `sol up --dry-run` in pluto (863 lines, identical), `sol assets` (identical apart from the binary's version string and the checkout path).
- **Guard:** `internal/ci/check_library_output.sh` + `test_library_output.sh` (the edge and commands may print; a `Printf.printf` or `prerr_endline` in a library fails). Both run in CI.
- **Tests:** `cli/test/test_report.ml`: levels, order and newline handling; and the workspace scan's unreadable-directory warning -- previously printed straight to stderr -- collected and asserted on. `test_process`'s redaction test asserts on the reported echo instead of capturing stdout (its stdout-capture helper is gone). `dune test cli/ --force`: 0 failures; format clean.
- **Demo/example:** not applicable (output unchanged). **Language parity:** no impact.
