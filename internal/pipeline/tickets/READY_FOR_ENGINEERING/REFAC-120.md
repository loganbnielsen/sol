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
