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
