---
id: REFAC-117
type: refactor
severity: low
title: sol alert test -- required --target, a library-built payload, and a typed send outcome
source: operator code-review notes (2026-09-26, sol-logan-comments), cli/bin/cmd_alert.ml
---

**Depends on:** REFAC-116.

## The problem

- `--target` is declared `opt (some string) None`, and its own doc says "Required"; the check happens by hand inside `run_test`.
- The synthetic alert payload is built in `cli/bin` and untested. It is pure data (the alert `sol alert test` pushes through the target's real route, as HARDEN-002's delivery evidence).
- Sending and printing are one `match`: an `Ok` branch prints an error.
- Two error paths print without `or_exit`/`or_exit_with`, because REFAC-111 converted only `error: %s` sites.

## Remediation

- `--target` is `required` at the Cmdliner layer.
- The payload moves to `cli/lib` with a unit test.
- Sending returns a typed outcome (`Accepted | Rejected of { exit_code; stderr } | Unreachable of string`), and a separate function renders it.
- Error paths go through `Sol_cli_exit`.

## Acceptance criteria

- `sol alert test` without `--target` is a Cmdliner usage error (test).
- Payload unit test.
- Output unchanged for accepted and rejected sends.
- Demo/example: not applicable (operator command, same interface); state it.

## Completion notes (2026-09-26)

Premise checked on `origin/main` (`1e23354b`): `--target` was `opt (some string) None` with its doc saying "Required"; the payload was built in `cli/bin`; sending and printing were one `match`.

- **`--target` is `required`** at the Cmdliner layer. Real binary: `sol alert test` with no target is a usage error, exit 124, `required option --target is missing`.
- **Payload and send live in the library:** `Sol_cli_alert_test` (`cli/lib/base`) provides:
  - `synthetic_alert ~owner ~runbook_url ~now` (the time is passed in, so it is testable);
  - `endpoint`;
  - `send`, returning `Accepted | Rejected { exit_code; stderr } | Unreachable reason`.

  `cmd_alert` renders the outcome (`report_outcome`) separately from obtaining it.
- **One exit, at the top:** `run_test` returns `(unit, Sol_cli_exit.failure) result` and composes with `let*`; the term calls `Sol_cli_exit.exit_on` once. This introduces REFAC-115's failure API: `failure = { text; code }`, `error ?code`, `failure ?code`, `exit_on`. It carries `sol alert test`'s exit 2 for a contract failure and the exact multi-line rejection text.
- **Output is unchanged:** accepted, rejected, dry run and the contract-failure message print as before (checked by hand with the binary, and pinned below).
- **Tests:**
  - `test_alert_test.ml`: payload labels and annotations, `startsAt` from `now`, no workload taxonomy labels, the endpoint, and a send to a closed port being `Rejected` with curl's exit 7;
  - a `cli/test/dune` rule running the real binary: exit 124 without `--target`, exit 2 for a contract failure, and a dry run printing the alert.
- Demo/example: not applicable (same operator interface).
- Language parity (DEC-022): no impact.
