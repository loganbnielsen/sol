---
id: REFAC-115
type: refactor
severity: medium
title: Only a command's run exits -- library code returns results, and assets are resolved once and validated
source: operator code-review notes (2026-09-26, sol-logan-comments), cmd_assets.ml and cmd_cloud_tf.ml
---

**Depends on:** None.

## The problem

Code below the command edge ends the process instead of returning an error. `rg -c '\bexit [0-9]' cli/lib --glob '*.ml'` counts 24 calls in 11 files (2026-09-26). Excluding the supervisor process, the exit helpers (`Sol_cli_exit`, `enter_or_exit`, `resolve_or_exit`) and shell text inside the scaffold templates, library functions print and exit: component values (`merged_values_yaml`), observability (`dashboard_configmap_yaml`, `alloy_values_yaml`), workspace discovery (`Sol_cli_manifest`), Docker, port-forwarding, and AWS destruction. Consequences:

- `sol assets` can only "check" those functions by calling them and `ignore`-ing the output, and it stops at the first failure.
- `cmd_cloud_tf` re-resolves the platform assets inside `asset_root`, `workdir` and `materialize_workdir`, that is, on every Terraform init, rather than once.

## Remediation

- Library functions return `result`; the command's `run` converts once with `Sol_cli_exit.or_exit`/`or_exit_with`.
- Resolve `Sol_cli_platform_assets` once per command and pass it down. Where a command needs the Terraform trees, validate their presence when resolving, so accessors cannot fail later.
- `sol assets` collects every check's result and reports all failures.

## Scope, sharpened by later review comments (2026-09-26)

"Exit too deep? Why not `let*`?" applies to `Sol_cli_exit.or_exit` as well. REFAC-111 placed `or_exit` calls inside command bodies, and each of those is an exit below the edge. The target shape: a command's `run` is a `let*` chain over `result`s, converted to a process exit **once**, at its top (the Cmdliner term), not a sequence of `or_exit` calls. This applies codebase-wide, not only at the sites the review named (`cmd_deploy.ml`, `cmd_assets.ml`, `cmd_cloud_tf.ml`).

## Acceptance criteria

- The remaining `exit` calls in `cli/lib` are listed in the completion notes, each with its reason.
- `sol assets` reports more than one failure in one run (test).
- Each command's body composes with `let*`; `rg -n 'or_exit' cli/bin` lists only one call per command entry point, with any exception named in the notes.
- No `ignore` of a consumer's output in `cmd_assets.ml`.
- Demo/example: not applicable (internal); state it.

## Progress

**Premise verified (2026-09-26):** `rg -c '\bexit [0-9]' cli/lib --glob '*.ml'` still counted exits in component values, observability, manifest discovery and AWS destruction before part A.

### Part A — library results and `sol assets` (landed)

- `Sol_cli_platform_component.merged_values_yaml`, `Sol_cli_dev_observability.{dashboard_configmap_yaml, render_alloy_config, alloy_values_yaml}` and `Sol_cli_manifest.discover_services` return `result`; the exiting variants are gone.
- `Sol_cli_aws_destruction.final_snapshot_interval_s` was a top-level value that exited while the module was being initialised, so a malformed `SOL_DESTROY_SNAPSHOT_INTERVAL_S` made **every** `sol` command exit 2, `sol --version` included. It is now a function returning `result`; a final-snapshot destroy with a bad interval is refused as `Preparation_failed … Block_destroy`. The offline lifecycle harness covers both halves.
- `sol local up` reads its component values, alloy values and dashboards once (`read_local_assets`) before deploying.
- `sol assets` collects every check into a `(string, string) result` and prints all failures, then "N of M asset checks failed" (exit 1). A dune rule runs it against a SOL_HOME that has lost two assets and expects at least two FAIL lines. Its body no longer `ignore`s any consumer output.
- The call sites that still convert with a temporary `Sol_cli_exit.or_exit`/`or_exit_with` in command bodies are the part B work list.

### Part B — every command returns its failure (landed)

Each command's `run` is a `let*` chain returning `(unit, Sol_cli_exit.failure) result`. The Cmdliner term converts it once with `Sol_cli_exit.exit_on`. The groups:

- **B1:** check, plan, target, open, rollback, releases, deployments.
- **B2:** secret, fn, status, logs.
- **B3:** deploy, up.
- **B4:** local, migrate.
- **B5:** cloud plan/apply/destroy, new.

Messages and exit codes are unchanged. A real-binary dune rule asserts them for about twenty failure paths. For the cloud and `sol new` paths I also compared the pre-change binary byte for byte, and they matched.

What changed along the way:

- **Helpers added:**
  - `Sol_cli_exit.of_msg` / `of_error`: a library error as a failure.
  - `reported ?code ()`: the command already printed why.
  - `exit_on` prints a failure as a complete line.
  - `Sol_cli_workspace.enter_cwd`, `Cmd_destination.remote`, `Sol_cli_deployment_plan.namespace_name` / `k8s_name` (these replace four copies of `namespace_or_exit`), and `Sol_cli_result.map_list`.
- **Helpers deleted:**
  - `Sol_cli_exit.or_exit` / `or_exit_with`, `Sol_cli_workspace.enter_or_exit`, `Sol_cli_platform_assets.resolve_or_exit`.
  - `Cmd_destination.or_exit` / `top`, and `Cmd_migrate.fatal` / `fatal_p`.
  - `cmd_cloud_tf`'s exiting twins: `platform_vars_of`, `with_cluster_access`, `require_credentials`, `lifecycle_error`.
- **Assets resolved once** (the Remediation's second point): `cmd_cloud_tf` resolves Sol's platform assets once per command and passes them to `asset_root`, `materialize_workdir` and both init forms.
- **Parser refusals (124)** for usage errors: `--observability-backend` is an `Arg.enum`, which removes three copies of `backend_of_arg`, and `--follow` with `--no-follow` is refused through `Term.ret`.
- **A latent exit on the deploy path, fixed:** `Cmd_migrate.read_applied_in_cluster` could exit through `pick_namespace_and_service`, `Sol_cli_substrate.ensure` or `read_migration_files`. That bypassed deploy's fail-closed "cannot verify the required migration state" guidance. These now arrive as `Unavailable`.
- **Resolve, then print:**
  - `sol status` resolves every namespace before it prints its domain table.
  - `sol logs --release` reads the store lazily, as before, and reports the store's own error instead of exiting inside the known-id callback.
- **Splitting and de-duplication:**
  - `sol local infra up` is split into four named phases.
  - One `reconcile_operator_bindings_warn` (via `Result.iter_error`) replaces the copies in deploy and migrate.
- **Docs:** `sol cloud destroy --help` no longer documents the exit 3 that REFAC-094 removed.

## Completion notes

- **`exit` calls left in `cli/lib`** (`rg -n '\bexit [0-9]' cli/lib --glob '*.ml'`, 2026-09-26):
  - `sol_cli_supervised.ml` (2, 127, 125): the supervisor process's own exit codes, which are its interface.
  - `sol_cli_exit.ml`: `exit_on`, the one conversion.
  - `sol_cli_scaffold_templates.ml`, `sol_cli_port_forward.ml:198`: shell text inside generated files, not OCaml.
  - `sol_cli_docker.ml:21`, `sol_cli_aws_destruction.ml:414`: comments.
- **`exit` calls left in `cli/bin`:**
  - Every term's single `exit_on`.
  - `cmd_local.ml`'s SIGINT handler (`exit 130`): a signal handler cannot return a result.
- **`rg -n 'or_exit' cli`** matches nothing; the helpers are gone. That is stronger than the criterion's "one call per entry point".
- **`sol assets`** reports every failure (part A's dune rule). `cmd_assets.ml` has no `ignore`.
- **Verification:** 65 CLI suites pass; format is clean; the offline lifecycle harness passes, including the REFAC-115 snapshot-interval scenario.
- **Demo/example:** not applicable. Internal: the command surface, messages and exit codes are unchanged, apart from the two usage errors that now come from the parser.
- **Language parity:** no impact (CLI-internal).
