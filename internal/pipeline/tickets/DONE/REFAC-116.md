---
id: REFAC-116
type: refactor
severity: medium
title: One way to say a process succeeded -- a result that is Ok only on exit 0, carrying stdout
source: operator code-review notes (2026-09-26, sol-logan-comments), cmd_alert.ml and cmd_cloud_tf.ml print_outputs
---

**Depends on:** None.

## The problem

`Sol_cli_process.run` returns `Ok` whenever the process started, whatever its exit status. Callers must add `Ok r when r.exit_code = 0` themselves: `rg -c 'exit_code = 0' cli --glob '*.ml' --glob '!cli/test/**'` sums to 71 (2026-09-26). So an `Ok` branch that reports an error reads as a contradiction (`cmd_alert.ml`). `run_ok` does return `Non_zero` for a failure, but it discards stdout.

## Remediation

- Add a variant that is `Ok stdout` only on exit 0, and `Error (Non_zero {…})` otherwise, with the exit code and stderr, via the existing error type.
- Move callers that only care about success onto it. Callers that branch on specific exit codes keep `run`, and name why.

## Acceptance criteria

- The remaining `exit_code` matches are listed in the completion notes, each with a reason (a meaningful specific code, or reading stdout on failure).
- Unit tests for the new variant: exit 0, non-zero, spawn failure.
- Demo/example: not applicable; state it.

## Completion notes (2026-09-26)

Premise checked on `origin/main` (`17afc4b2`): `rg -c 'exit_code = 0' cli --glob '*.ml' --glob '!cli/test/**'` summed to 71, plus 9 `exit_code <> 0` checks.

**API** (`Sol_cli_process`):
- `check`: `Ok` only for exit 0; any other exit is `Error (Non_zero { exit_code; stdout; stderr })`. `Non_zero` gained `stdout`.
- `run_success = check ∘ run`; `output`, its stdout; `run_ok`, the same with no output.
- `failure_output ~stdout ~stderr`: what a failed command said, trimmed stderr else stdout.
- `run` stays, documented as the call for when a specific non-zero exit means something.

**Call sites.** Every success-only site is converted, codebase-wide, in four shapes:
- `Ok r when exit_code = 0 → A | Ok r → B` becomes `Ok r → A | Error (Non_zero r) → B`, with the scrutinee wrapped in `check`, or with `run_success`/`output` at the call.
- `Ok r → r.exit_code = 0 | Error _ → false` becomes `Result.is_ok (run_ok …)`.
- A success guard with an extra condition (`&& stdout <> ""`) keeps only the extra condition.
- `Ok r when exit_code <> 0` branches become `Error (Non_zero r)` branches, placed before the generic `Error e`.

**Also consolidated** (the same "hand-rolled" theme):
- Four private "what did the failure say" helpers now go through `failure_output`: `detail_of_result` ×2, `process_detail`, and inline `if stderr <> "" then … else stdout`.
- `Sol_cli_kubectl.get` and `Sol_cli_loki` had rebuilt `Non_zero` by hand; both now use `run_success`.
- `rollback`'s and `secret`'s duplicated "cluster doesn't serve this resource type" test is now `Sol_cli_kubectl.resource_type_absent`.
- `kubectl_read_failure` takes the failure's fields.
- `exit_code_of` (unused) is deleted.

**Latent bug fixed.** `Sol_cli_release_store.get`'s NotFound branch matched `Ok r when exit_code <> 0`. That can never happen, because `Sol_cli_kubectl.get` already returned `Error Non_zero` for a failure, so a missing release read as a generic kubectl failure. Proven on unmodified `origin/main`: the new test `a missing release is not found` fails there with `exited with code 1: Error from server (NotFound): …`, and passes here. A companion test checks that a forbidden read stays an error carrying kubectl's reason.

**What still reads an exit code** (`rg -n 'exit_code (=|<>) [0-9]' cli --glob '*.ml' --glob '!cli/test/**'`), each deliberately:
- `sol_cli_loki.ml`: curl 28 (timeout) and 6/7/56 (connection) classify a failure, now via `Non_zero`.
- `sol_cli_cloud_lifecycle.ml`: `kubectl auth can-i` exits 1 for "no", which is an answer, not a failure (`Sol_cli_kubectl.probe_result` feeds it).
- `sol_cli_run_log.ml` and `sol_cli_destruction.ml` record every phase's status; `ok` is now `Result.is_ok (check result)`.

**Tests.** `test_process.ml` covers `run_success`/`output` (exit 0, non-zero keeping both streams, spawn failure), `check` idempotence and `failure_output`. `test_release_store.ml` covers the read tests above. The full `dune test cli/ --force` passes (61 suites), including the offline lifecycle harness, which drives most converted Terraform, kubectl and aws paths through fake binaries.

**Method, for the record.** A first pass by line-based rewriting mis-scoped two sites (a nested `match` rebinding `r`, and a multi-line regex that crossed function boundaries). Both were caught by the compiler and review, reverted, and redone with exact-text edits. The final diff (39 files, after merging `main` with REFAC-119) was then read hunk by hand. Every hunk preserves behaviour except the intended "release not found" fix. One small difference: `rollback`'s resource-type test now reads trimmed output, and its error text was already trimmed.

- Demo/example: not applicable (internal; user-facing messages unchanged, except that a missing release now reads as "not found").
- Language parity (DEC-022): no impact.
