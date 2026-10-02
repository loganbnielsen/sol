---
id: VERIF-016
type: bug
severity: medium
title: 'A unit suite prints [skip] and passes when the ambient environment already holds the variable it means to test'
source: internal/pipeline/audits/2026-10-02_test_suite_audit.md
premise: '! rg -q -F "[skip] AWS_LAMBDA_RUNTIME_API" framework/ocaml/sol-fn/test/test_fn.ml'
---

A unit suite prints `[skip]` and passes when the ambient environment already holds the variable it means to test

**Depends on:** None.

**Premise verified (2026-10-02)** against `origin/main @ 310917dd`:
`framework/ocaml/sol-fn/test/test_fn.ml:213-228`:

```ocaml
let test_lambda_trigger_requires_runtime_api () =
  if Sys.getenv_opt "AWS_LAMBDA_RUNTIME_API" <> None
  then Printf.printf "[skip] AWS_LAMBDA_RUNTIME_API is set in this environment — skipping\n%!"
  else
    …
    match M.run ~env () with
    | Error (`Config msg) -> … contains "AWS_LAMBDA_RUNTIME_API is not set" msg
    | _ -> Alcotest.fail "expected config error"
```

The suite already contains a `with_env` helper at `:167-171`.

## Problem

The case asserts that a `Lambda`-triggered function fails closed with a config error when
`AWS_LAMBDA_RUNTIME_API` is unset. If the variable happens to be set — exactly the environment that
resembles Lambda — the case prints a line and returns, and the suite is still green. A reader sees a
passing run and cannot tell that the one negative path this case exists for was not exercised.
Unlike the `EPERM` skips (`framework/ocaml/sol-obs/test/test_sol_obs.ml:17-18`,
`framework/ocaml/sol-worker/test/test_worker.ml:243-246`, owned by `VERIF-006`), the missing input
here is a single environment variable. It cannot be *unset* from OCaml — `Unix` exposes
`getenv`/`putenv`/`environment` but no `unsetenv` (verified: compiling `Unix.unsetenv "X"` against
this switch's `unix.mli` is `Error: Unbound value Unix.unsetenv`) — so the case cannot create the
condition it needs. That is exactly why it must fail rather than pass when it cannot: the current
`[skip]` reports the opposite of what happened.

## Desired invariant

A case never skips on ambient state it can control. An omitted optional dependency produces a
distinct, visible, non-passing outcome, or the case sets up the condition it needs and always runs.

## Remediation

Because `AWS_LAMBDA_RUNTIME_API` cannot be unset from OCaml, make the case fail closed: when the
variable is set, `Alcotest.fail` naming the precondition; when it is unset, run the assertion.
Setting it to `""` is not equivalent — `lambda-eio`'s `runtime_api_base` accepts `Some ""` as a
usable base, so an empty value reaches a different branch.

## Acceptance criteria

- `test_lambda_trigger_requires_runtime_api` asserts the missing-runtime-API config error when the
  variable is unset, and fails loudly naming the precondition when it is set; it never prints
  `[skip]` and returns.
- No unit case reports success on ambient state it could not establish.

## Completion (2026-10-02)

Implemented on `VERIF-016/lambda-skip`: `framework/ocaml/sol-fn/test/test_fn.ml` now matches on
`Sys.getenv_opt` and `Alcotest.fail`s when the variable is set, otherwise runs the original
assertion. Verified locally both ways — the suite reports `10 tests run` and success with the
variable absent, and one named failure ("unset the variable for this run") with it present.
Demo/example: not applicable — test-only. Language parity: no application-facing contract change.
Remaining limitation: because OCaml cannot unset the variable, a developer running under a Lambda
Runtime Interface Emulator gets a failure they must dismiss by unsetting it; that is the intended
fail-closed signal rather than a silent pass.
