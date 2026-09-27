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
