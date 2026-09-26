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
