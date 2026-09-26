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

## Acceptance criteria

- The remaining `exit` calls in `cli/lib` are listed in the completion notes, each with its reason.
- `sol assets` reports more than one failure in one run (test).
- No `ignore` of a consumer's output in `cmd_assets.ml`.
- Demo/example: not applicable (internal); state it.
