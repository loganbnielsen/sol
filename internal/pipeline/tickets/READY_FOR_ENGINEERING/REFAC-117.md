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
