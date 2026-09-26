---
id: REFAC-120
type: refactor
severity: low
title: Write down the pipeline convention -- a list goes first, then |> into the function applied to it
source: operator code-review notes (2026-09-26, sol-logan-comments), cmd_assets.ml and cmd_check.ml
---

**Depends on:** None.

## The problem

Calls like `List.iter (fun … -> <many lines>) Sol_cli_provider.all` put the data last, after a long anonymous function, so the reader finds what is iterated only at the end. `cmd_check`'s `let findings = match … in List.iter … findings` is the same shape.

## Remediation

- A short convention in `CONTRIBUTING.md`: when the function argument is more than a line, lead with the data: `xs |> List.iter (fun x -> …)`. A value computed only to be consumed by the next line becomes a named function feeding a pipeline (`findings_for scope |> report`).
- Apply it to the sites the review named (`cmd_assets.ml`, `cmd_check.ml`). Other code follows as it is touched; no sweep.

## Acceptance criteria

- The convention is in `CONTRIBUTING.md`, and the named sites follow it.
- Demo/example: not applicable; state it.
