---
id: REFAC-154
type: refactor
severity: low
title: Use direct monadic composition for semantically empty bindings
source: Logan code review (2026-09-28)
---

Use direct monadic composition for semantically empty bindings

**Depends on:** None.

## Principle

Review the CLI and supporting OCaml libraries for `let* value = operation () in
next_operation value` where the value is used exactly once, passed unchanged, and the
continuation performs no additional work. Use direct monadic composition when removing
the name makes the data flow clearer.

Keep `let*` when the name conveys a domain phase, the value has multiple uses, the next
expression transforms it or supplies additional arguments, or point-free composition
would obscure types, intent, or control flow. This complements REFAC-149: normalize
meaningful inputs before application, but do not introduce semantically empty names.

## Remediation

- Manually inspect `cli/`, `framework/ocaml/`, examples, scaffold templates, and
  `internal/tooling/`, then inspect pinned supporting libraries where this pattern exists.
- Follow existing bind conventions. OCaml's standard `Result.bind` takes the result
  first: use `Result.bind (operation ()) next_operation`, or the existing pipeline form
  `operation () |> Fun.flip Result.bind next_operation`. The superficially similar
  `operation () |> Result.bind next_operation` has the wrong argument order.
- Reuse a module's existing `>>=` only when it already denotes the relevant monad;
  introduce no new operator for this sweep. Apply the same reasoning to `Option.bind`.
- Record this decision criterion in the style audit and contributing conventions.

## Acceptance criteria

- Completion notes name reviewed folders, high-confidence replacements, and examples
  retained because the binding carries useful meaning.
- Replacements preserve evaluation order, short-circuiting, error types, and behavior.
- No new bind operator or generic composition helper is introduced.
- Focused existing tests and builds pass for each changed subsystem.
- Demo/example and language-parity impact are recorded per changed surface.

## Premise verification

Before implementation, manually identify qualifying sites and record exact examples.
An occurrence of `let*` alone is not evidence that its name is unnecessary.
