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
here is a variable the test can control, so the skip is avoidable rather than environmental.

## Desired invariant

A case never skips on ambient state it can control. An omitted optional dependency produces a
distinct, visible, non-passing outcome, or the case sets up the condition it needs and always runs.

## Remediation

Add an `unset_env` sibling to the existing `with_env` helper and run the case with
`AWS_LAMBDA_RUNTIME_API` removed for its duration, so it exercises its claim on every host.

## Acceptance criteria

- `test_lambda_trigger_requires_runtime_api` runs and asserts on a host where
  `AWS_LAMBDA_RUNTIME_API` is set; it no longer prints `[skip]` and returns.
- No unit case chooses to skip on an environment variable it could unset.
- Demo/example: not applicable — test-only change. Language parity: no application-facing contract
  change; state that in one line.
