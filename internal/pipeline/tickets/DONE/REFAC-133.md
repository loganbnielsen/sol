---
id: REFAC-133
type: refactor
severity: medium
title: No exceptions for control flow in the CLI -- Deploy_failed goes, and library code returns its Error instead of failwith
source: pattern audit of the REFAC-104..130 series (2026-09-26); follows REFAC-115's "a command's run is a let* chain"
premise: "! rg -q 'Deploy_failed' cli"
---

**Depends on:** None.

## The problem

REFAC-115 made every command a `let*` chain converted to an exit once. Underneath, results are still converted to exceptions and back:

- `Sol_cli_manifest.Deploy_failed` is raised from `Result.iter_error` in `cli/bin/cmd_up.ml:85-122` and `cmd_rollback.ml:60`, raised from `sol_cli_manifest.ml:135-187`, and caught again in `cmd_deploy.ml:274` / `cmd_rollback.ml:69` to rebuild the `Error`.
- Library functions throw away a perfectly good `Error`: `Sol_cli_executor.local`/`gitops` (`failwith msg`), `Sol_cli_toml.load` (`failwith`, beside a `load_result` that already returns the error), `Sol_cli_release_inspection:215`, `Sol_cli_deployment_plan:1079`, `sol_cli_scaffold.ml` (four `raise`s).

`rg -n --glob '*.ml' '\b(failwith|invalid_arg|raise)\b' cli/lib cli/bin` (2026-09-26) lists these alongside a few genuine programmer-error invariants.

## Remediation

- Delete `Deploy_failed`; the functions that raised it return `result` and their callers compose with `let*`.
- Every `| Error e -> failwith …` / `invalid_arg …` on a runtime condition returns the `Error`. Where a raising and a result-returning variant both exist (`Sol_cli_toml.load`/`load_result`), keep only the result.
- What may still raise is a *programmer* error on a static value (e.g. a literal default that fails its own parser, a length-mismatch invariant). Each such site is listed in the completion notes, and a test rule fails on a new `failwith`/`raise` in `cli/lib` outside an explicit allow-list.

## Acceptance criteria

- `rg -n 'Deploy_failed' cli` prints nothing.
- The remaining `failwith|invalid_arg|raise` sites in `cli/lib`/`cli/bin` are listed with why each is an invariant, not a runtime failure.
- The test rule exists and fails on a planted `failwith` (positive control).
- Error text and exit codes unchanged (existing CLI tests and the real-binary dune rules).
- Demo/example: not applicable (internal). Language parity: no impact.

## Completion notes

**Premise verified (2026-09-27, `origin/main` at `46d51f14`):** `rg -n 'Deploy_failed' cli` found the exception declared in `sol_cli_manifest.ml`, raised there and in `cmd_up.ml` (×7) / `cmd_rollback.ml`, and caught in `cmd_up`, `cmd_deploy`, `cmd_rollback`; `rg -n 'failwith|invalid_arg' cli/lib` listed the `Error -> failwith` sites named above.

- **`Deploy_failed` is gone.** `Sol_cli_manifest.apply` returns `(unit, string) result` (each kubectl step's error behind the same prefix as before; the temp file is removed in a `Fun.protect` finally instead of a catch-all that re-raised). `Sol_cli_executor.local`/`gitops` return results, and `run_plan`'s render-all-then-find-the-first-error block is a `let*` fold with the same first-error-in-order behaviour. `cmd_up`'s `apply_service` is split into `deploy_service` (build, push, apply, wait -- the steps whose failure fails the run, a `let*` chain) and `expose_service` (the port-forward, which reports and never fails the release); the dry-run and apply loops are folds that stop at the first failure. `cmd_rollback.apply_specs` and `cmd_deploy.run_plan_result` lose their `try … with Deploy_failed`.
- Found along the way: `Sol_cli_up_execution.apply_service_manifest` caught `Failure` but not `Deploy_failed`, so a kubectl apply failure there bypassed it and reached `cmd_up`'s outer handler; with results there is nothing to miss.
- **Raising variants removed** where a result-returning one existed: `Sol_cli_toml.load` (tests use `load_result`; its doc's validation list moved onto `load_result`), `Sol_cli_deployment_plan.of_services` and `namespace_of_exn` (tests unwrap `namespace_result`), and `service_url` -- both planner call sites already held the validated namespace and now pass it to `Sol_cli_kubernetes_name.service_url` directly. `Sol_cli_release_inspection.rendered_manifests_of_plan` returns a result. The Alloy template slicer returns an `Error` for a missing marker (a changed asset file is a runtime condition). `Sol_cli_supervised`'s interrupt forwarder was a `while` loop broken with `raise Exit`; it is a recursive function.
- **What may still raise, each an invariant** (the list lives in `internal/ci/check_no_exception_control_flow.sh`, with its reason): `Sol_cli_time` (a float Ptime cannot represent), `Sol_cli_yaml` ×2 (NUL is refused at the boundaries first; the emitter buffer grows until it fits), `Sol_cli_terraform.targets` (literal addresses, or addresses read from state), `Sol_cli_deployment_plan`'s two literal default quantities, `Sol_cli_factory`'s one-to-one length check, `Sol_cli_local_infra`'s literal concurrency bound; and `… as exn -> raise exn` re-raising cancellation/fatal exceptions. **`Sol_cli_scaffold.mkdir_p`** still raises `Failure` on a filesystem error: it is the helper REFAC-134 replaces with a result-returning `Sol_cli_fs`, and its allow-list entry names that ticket.
- **Guard:** `check_no_exception_control_flow.sh` + `test_no_exception_control_flow.sh` (four cases: results/invariant/re-raise/prose pass; `failwith` on an `Error`, a command-defined exception, and an unlisted raise in an allow-listed file each fail -- the last one caught an over-broad allow-list entry while writing it). Both run in CI.
- **Verified:** `dune build`; `dune test cli/ --force` 0 failures (including the real-binary exit-code rules); format clean; `sol up --dry-run` in pluto renders the same 37 documents, exit 0.
- **Demo/example:** not applicable (internal; messages and exit codes unchanged). **Language parity:** no impact.
