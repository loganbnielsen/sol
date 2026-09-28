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

Single use is a candidate filter, not a refactoring requirement. Removing a meaningful
phase name to obtain a less readable prefix `Result.bind` is a regression. Positive
example: replace `let* cfg = apply ... in Ok cfg` with `apply ...`. Negative example:
retain `let* creds_json = classify_imdsv2_response ... in
resolved_of_json_credentials creds_json`; the name identifies the classified credentials
JSON phase before credential resolution.

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

## Completion (2026-09-28)

- Verified the premise by reading CLI command/request resolution and supporting
  library continuations: the final config target-layer application was followed
  only by `Ok cfg`. Returning that application directly removes an identity bind.
- Manual sweep covers cli/bin, all six CLI library domains, framework/ocaml,
  examples, scaffold templates, internal/tooling, and supporting kafka-eio,
  pg-eio, aws-eio, s3-eio, dynamodb-eio, lambda-eio, https-eio and the four obs
  packages (core, Loki, Prometheus, Tempo).
- Retained phase names in target/config resolution, JWT validation, IMDS token/
  role/credentials decoding, and request authentication. Also retained `let* ()`
  sequencing and transaction begin/commit/rollback boundaries. The AWS proposal
  was withdrawn without merging (aws-eio PR #28): `creds_json` adds domain meaning.
- REFAC-148 already simplified mechanical forwarding in release pointer updates
  and job dispatch; this sweep does not replace meaningful bindings with prefix
  combinators just because the values have one use.
- CONTRIBUTING and the style audit's source-of-truth checklist now include the
  positive config example and negative credentials example. The style-audit skill
  consumes that checklist, so its guidance follows the conservative distinction.
- Validation: CLI build and all 87 config tests pass; formatting/diff checks pass.
- Demo/example: not applicable; internal config resolution behavior is unchanged.
  No language-parity impact: no application contract changes.
