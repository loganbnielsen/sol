---
id: REFAC-129
type: refactor
severity: medium
title: Make the sol.yml / environments decoder read simply -- named error helpers, let* over results, no assert false
source: operator review (2026-09-26, sol-logan-comments), cli/lib/workspace/sol_cli_config.ml decode_layer and members
---

**Depends on:** None.

## The problem

The operator's comments on `Sol_cli_config`:

- On `members`: "this seems quite hard to read... is it simple?"
- On `value`, which matches `scalar_text` into `Ok s` or `fail …`: "Option.toResult?" and "Failing so deep? Why not Result that bubbles to the top via let*?" Then: "I see now that fail doesn't raise... are we redefining fail then? seems like we should just call error or something or what's the more conventional name for this?"
- On `int_value`'s `match parse_int … | Error msg -> fail (msg ^ …)`: "mapLeft or wait to fail instead of failing so deep?"
- On "A nested value under a provider field is ignored, as it always was": "comment is a bit confusing? is this hacky? do we need a better solution?"
- On the `assert false` closing `decode_target_fields`'s key match: "move above and pipe?"

The decoder is correct, but it names its error constructor `fail`, which reads like an exception. It re-matches results by hand where `Option.to_result` / `Result.map_error` would do. It reaches the `assert false` because one match handles two different kinds of key. And it silently ignores a nested value under a provider field.

## Remediation

- Rename the local helpers after what they return: `error` / `error_at ~path` for a decode error, not `fail`. Use `Option.to_result ~none:(error …)` and `Result.map_error` rather than re-matching, and a `let*` chain per decoded field.
- Split target-key classification into a type: plain keys versus provider blocks versus provider-owned versus unknown. Each match is then total over its own type and needs no `assert false`. Decode the plain keys with a table or a pipeline.
- Decide the nested-value case instead of ignoring it. A nested value under a provider field is refused, naming the key, unless a real config uses it. Check the examples and fixtures first, and record what was found.
- Rewrite `members` as a fold with named steps (duplicate check, alias refusal, key extraction) so it reads top to bottom.

## Acceptance criteria

- No `assert false` in `sol_cli_config.ml`; no local helper named `fail` that returns a value.
- Error messages are unchanged. The existing config tests pass as they are, except the nested-provider-value case, whose new behaviour has a test.
- Demo/example: not applicable (internal), unless the nested-value decision changes accepted config, in which case the docs say so.
- Language parity: no impact.

## Completion notes

- **The decoder reads as a chain.** The local helper is `error` / `error_at` (no
  `fail` that returns a value); `Option.to_result` and `Result.map_error` replace the
  hand-rolled re-matching, and the decoded fields are a `let*` chain. `assert false`
  is gone: target keys are classified by a type first, so each match is total over its
  own type.
- **`members` is a fold with named steps** (`key_of`, `no_alias`, `add`), so a
  duplicate check, an alias refusal and key extraction read top to bottom.
- **The nested-provider-value case is decided, not ignored.** A nested value under a
  provider field was dropped silently, so a typo was indistinguishable from not
  writing the field; it is now refused with `aws.vpc must be a single value, not a
  nested block`. Checked first, as the ticket required: **no config in `sol.yml`
  examples, `examples/pluto` or `internal/fixtures/` nests one**, so nothing in the
  repository changes meaning. Because accepted config does change for such a file,
  `docs/deployment/production-bootstrap.md` now states the rule, and the test that
  asserted the old tolerance asserts the refusal instead.
- **Tests:** `test_config` 87 cases pass, including the rewritten nested-value case;
  error messages are otherwise unchanged. `dune build` clean;
  `internal/ci/check_ocamlformat.sh --all` clean.
- **Demo/example:** not applicable — no generated or example config carries a nested
  provider field; the docs sentence above is the whole user-visible change.
- **Language parity:** no impact (deployment config is language-neutral).
