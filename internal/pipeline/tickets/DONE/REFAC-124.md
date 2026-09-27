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
- Adapters keep the underlying error instead of replacing it with a fixed string. `Sol_cli_kubectl.probe_result` maps every process error to `"kubectl could not be run"`, losing the spawn/timeout detail (operator: "why remap the error instead of keeping the original? map instead?"). Use `Result.map` over the success and pass the `Sol_cli_process.error` through, rendered once where it's shown.
- Update the REFAC-116 regression tests to the new shape. Keep the `exit 3` / `Non_zero` coverage.

## Acceptance criteria

- `Sol_cli_process.mli` exports a single run function (plus `run_shell` if it's still needed, with the same contract).
- `git grep -n 'Sol_cli_process\.\(check\|run_success\|run_ok\)' -- cli` prints nothing.
- The existing tests pass. The behaviour of every command is unchanged; `failure_output` still gives the stderr-else-stdout text.
- Demo/example: not applicable (internal). Language parity: no impact (CLI-internal).

## Completion notes

**Premise verified (2026-09-26):** `git grep -c` over `cli` on origin/main found `Sol_cli_process.check` 48 times, `run_success` 16, `run_ok` 14 and `output` 3, next to a raw `run` that was `Ok` for any exit.

- **`Sol_cli_process` exports one runner.** `run : ?echo -> cmd -> (output, error) result` is `Ok { stdout; stderr }` only on exit 0. `run_shell` has the same contract. `completed ~exit_code ~stdout ~stderr` builds that result for the supervisor, which waits on terraform itself. `check`, `run_success`, `run_ok` and `output` are gone.
  - `git grep -n 'Sol_cli_process\.\(check\|run_success\|run_ok\)\b' -- cli` prints nothing.
  - The `output` matches that remain are the type name, not the removed function.
- **`Sol_cli_kubectl`:**
  - One local `kubectl ?timeout_s ~ctx args`; every adapter is a one-liner over it.
  - `probe_result` keeps the underlying process error ("kubectl could not be run: …") instead of replacing it.
- **Sites where a non-zero exit was an answer** now match `Error (Non_zero _)`:
  - the destroy verification's provider query;
  - `kubectl auth can-i`, whose "no" is exit 1;
  - the kubectl probe;
  - `sol status`'s curl probe. curl exits 7 on a refused connection and prints `000`; confirmed with `curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:1` → `000 rc=7`. Without this, "connection failed" would have become "exited with code 7".
- **Sites that silently change meaning.** The compiler can't see a site that matched `Ok` without reading the exit code, so I listed them with a script over origin/main: every call to a raw-result wrapper with no success check within a few lines. Each flagged site was read by hand. Apart from curl, a non-zero exit there now reads as the failure it was (a failing `terraform output`, a failing `kubectl get pods` or `logs`) instead of as empty output.
- **One dead arm removed:** the whoami retry in `Sol_cli_aws_cluster` had an unreachable `Ok (Ok r)` arm since REFAC-116. The nested result is flattened first, so a kubectl exit now renders as the intended "kubectl exited N (…)".
- **Tests:** the REFAC-116 regressions are rewritten to the new shape. Non-zero is `Non_zero` with the code and both streams, for `run` and `run_shell`, and `completed` has its own test. 66 CLI suites pass; format is clean; the offline lifecycle harness passes.
- **Demo/example:** not applicable (internal). **Language parity:** no impact (CLI-internal).
