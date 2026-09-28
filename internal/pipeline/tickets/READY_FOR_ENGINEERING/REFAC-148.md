---
id: REFAC-148
type: refactor
severity: low
title: Propagate unchanged Result errors instead of matching them by hand
source: Logan code review (2026-09-27), generalized from cmd_assets template planning
---

Propagate unchanged `Result` errors instead of matching them by hand

**Depends on:** None.

**Premise verified (2026-09-27):**
`rg --pcre2 -n -U '\| Error ([a-zA-Z_][a-zA-Z0-9_]*) -> Error \1' --glob '*.ml' cli framework examples internal`
finds 55 sites on `origin/main` at `52c01e21`. Positive controls include
`cli/bin/cmd_assets.ml:80`, `cli/lib/workspace/sol_cli_toml.ml:88`, and
`framework/ocaml/kafka-eio-service/lib/kafka_service_retry_topics.ml:67`.

## The principle

When a match does nothing with `Error e` except return the same `Error e`, propagate it
with `let*`, `Result.bind`, or an existing Result combinator. The remaining code should
express only the next domain decision. This is OCaml's equivalent of chaining a
fallible computation: error forwarding is plumbing, not business logic.

Do not mechanically rewrite a match whose error type changes, whose success path is not
sequential, or whose explicit branches make ownership clearer.

## Remediation

- Add the rule to `CONTRIBUTING.md` beside `Result.Syntax`.
- Manually review all 55 seeds across production code, examples, and copied templates;
  use the search only as a candidate list.
- Replace high-confidence unchanged-error forwarding with a linear Result pipeline.
- Keep examples and scaffold templates aligned when either teaches the affected shape.

## Acceptance criteria

- Production, example, and scaffold code contains no manual unchanged-error forwarding
  where `let*` or an existing Result combinator makes the next domain decision clearer.
- Every retained seed is named in completion notes with the reason its explicit match is
  clearer or semantically necessary.
- The contributing convention includes one before/after example and warns against
  changing error types accidentally.
- Focused tests cover any rewritten branch that adds domain validation after the bind.
- Demo/example and language-parity impact are recorded per changed site.

