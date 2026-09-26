---
id: REFAC-124
type: refactor
severity: medium
title: One way to run a process -- Sol_cli_process.run is Ok only on exit 0, and check, run_success and run_ok go
source: operator review (2026-09-26, sol-logan-comments), sol_cli_process.ml and sol_cli_kubectl.ml
---

**Depends on:** None.

## The problem

REFAC-116 made "the process succeeded" expressible, but left five entry points: `run` (Ok whenever the process ran), `check` (converts that to success), `run_success` (`check (run c)`), `output` (its stdout) and `run_ok` (its unit). The operator's comments:

- On `check`: "two mappings for Ok?"
- On `Sol_cli_kubectl.apply_dry_run`: "why run and run_ok? can we simplify to have result types only?"
- On `Sol_cli_kubectl.invocation`: "invocation + Sol_cli_process.run seems heavy".

`git grep -c` over `cli` on origin/main (2026-09-26) gives: `run` 31, `check` 48, `run_success` 16, `run_ok` 14, `output` 3. Each tool wrapper (`Sol_cli_kubectl`, `Sol_cli_terraform`, …) chooses one of these per function, so every reader has to know which one it chose.

## Remediation

- **One function:**
  ```ocaml
  run : ?echo:bool -> cmd -> ({ stdout; stderr }, error) result
  ```
  It is `Ok` only on exit 0. `error` stays `Spawn_failed | Non_zero { exit_code; stdout; stderr } | Timeout`.
  - A caller for whom a particular non-zero exit means something (for example "not found") matches `Error (Non_zero r)`. That is the only use `run`'s "Ok whatever the exit" had.
  - Remove `check`, `run_success` and `run_ok`. Unit callers write `let* _ = …` or `Result.map ignore`.
  - Keep `output` only if it still pays for itself after the sweep.
- **Tool adapters return results the same way.** `Sol_cli_kubectl` gets one local `kubectl ~ctx args = Sol_cli_process.run (invocation ~ctx args)`, and its functions are one-liners over it. Terraform, Helm, Docker, aws and gcloud follow the same pattern. No wrapper returns an unchecked `run` result.
- Update the REFAC-116 regression tests to the new shape. Keep the `exit 3` / `Non_zero` coverage.

## Acceptance criteria

- `Sol_cli_process.mli` exports a single run function (plus `run_shell` if it's still needed, with the same contract).
- `git grep -n 'Sol_cli_process\.\(check\|run_success\|run_ok\)' -- cli` prints nothing.
- The existing tests pass. The behaviour of every command is unchanged; `failure_output` still gives the stderr-else-stdout text.
- Demo/example: not applicable (internal). Language parity: no impact (CLI-internal).
