---
id: REFAC-120
type: refactor
severity: low
title: Write down and apply the readability conventions -- pipelines, no redundant annotations, named single-purpose functions
source: operator code-review notes (2026-09-26, sol-logan-comments), cmd_assets.ml and cmd_check.ml
---

**Depends on:** None.

## The problem

Calls like `List.iter (fun … -> <many lines>) Sol_cli_provider.all` put the data last, after a long anonymous function, so the reader finds what is iterated only at the end. `cmd_check`'s `let findings = match … in List.iter … findings` is the same shape.

## Remediation

- A short convention in `CONTRIBUTING.md`: when the function argument is more than a line, lead with the data: `xs |> List.iter (fun x -> …)`. A value computed only to be consumed by the next line becomes a named function feeding a pipeline (`findings_for scope |> report`).
- Also in the convention: no redundant type annotations or module-qualified labels on lambdas whose type is already known (`fun (r : Sol_cli_executor.result) -> r.Sol_cli_executor.name` becomes `fun r -> r.name`); and a function doing two jobs (e.g. `cmd_deploy.print_service_urls`, which resolves URLs and prints them) is split, with names that say its role.
- Also: a `match` whose `Ok` arm is `()` and whose only work is on `Error` becomes `Result.iter_error` (operator comment "unwrap?" on `cmd_deploy.reconcile_operator_bindings_warn`, 2026-09-26); likewise `Option.iter` for a `None -> ()` arm.
- **Apply it codebase-wide.** The operator's comments are examples of rules, not a list of sites (2026-09-26), so this is a sweep of `cli/`, not only the named sites.

## Acceptance criteria

- The convention is in `CONTRIBUTING.md`, and `cli/` follows it; the completion notes say how the sweep was checked.
- Demo/example: not applicable; state it.

## Completion notes

**Premise verified (2026-09-26):** the counts below, measured on origin/main.

- **The convention** is a new `## Code conventions` section in `CONTRIBUTING.md`. Besides this ticket's rules (lead with the data, resolve then print, no redundant annotations or qualifiers, a no-op arm is `iter`, eta-reduce), it records the rules the operator stated while this series ran:
  - `Result.Syntax`, with the test rule that enforces it;
  - nothing below a command's term exits (REFAC-115);
  - blank is decided at the boundary (REFAC-123);
  - keep a tool's original error text, with classification as a view (REFAC-125);
  - ask the tool for a structured answer (REFAC-125).
- **How the sweep was checked.** Each mechanical pass was a script, followed by `dune build`, `dune fmt`, and the full CLI suite. Measured with `count.py`'s patterns over `cli/**/*.ml` (scaffold templates excluded):

  | | origin/main | this branch |
  |---|---|---|
  | multi-line lambda before its data (`List.iter\n (fun …) xs`) | 296 | 86 |
  | annotated lambda parameters | 115 | 88 |
  | module-qualified field accesses (`r.M.field`) | 460 | 73 |
  | two-arm no-op matches | 32 | 9 |

- **What remains, and why:**
  - **Pipelines.** The 86 were skipped on purpose: calls with a non-lambda first argument, several data arguments, or an infix operator after the call, where `|>`'s low precedence would change the parse.
  - **Annotations and qualifiers.** These passes removed every one, rebuilt, and restored only those the compiler then required: 50 annotated-lambda lines and 383 qualified accesses are gone. What remains is needed, typically because a record constructed before its use fixes the type, or because an opened module shares the field name (`cmd_deploy`'s `open Sol_cli_manifest`).
  - **No-op arms.** The 9 have guards, more than two arms, or no unambiguous extent.
- **Two-job functions:**
  - `cmd_deploy.print_service_urls`, which your review named, is now `http_services` (resolves) and `print_service_urls` (prints).
  - `cmd_status.print_signal_line` is now `signal_line` (returns the line), printed by its caller.
  - Along the way, `Sol_cli_status.Unreachable` now carries the probe's own reason ("unreachable (HTTP 503)") instead of discarding it. That is the keep-the-original-text rule.
- **Verification:** 67 CLI suites pass; format is clean; the offline lifecycle harness passes.
- **Demo/example:** not applicable (internal). **Language parity:** no impact.
