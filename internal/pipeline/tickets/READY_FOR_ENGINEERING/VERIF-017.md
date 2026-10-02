---
id: VERIF-017
type: refactor
severity: medium
title: 'Module-level mutable fixtures are shared by every test in a module'
source: internal/pipeline/audits/2026-10-02_test_suite_audit.md
premise: '! rg -q "^let written :" cli/test/support/targets_fixture.ml && ! rg -q "^let current_pool = ref None" framework/ocaml/sol-jobs/test/test_sol_jobs_pg.ml'
---

Module-level mutable fixtures are shared by every test in a module

**Depends on:** None.

**Premise verified (2026-10-02)** against `origin/main @ 310917dd`:
`cli/test/support/targets_fixture.ml:1` is
`let written : (string, (string * string) list) Hashtbl.t = Hashtbl.create 8`, and
`framework/ocaml/sol-jobs/test/test_sol_jobs_pg.ml:266` is `let current_pool = ref None`. These are
the only two module-level mutable values in the test trees (`rg '^let .*ref|^let .*Hashtbl'`).

## Problem

Windtrap builds one runner per module, so the tests in a module share a process: module-level
mutable state is cross-test state even though separate modules are isolated. `written` keys its
accumulated target entries by `Sys.getcwd ()`, so two tests that happen to share a working
directory share the rendered `sol/environments.yml`; `current_pool` is written by one test and read
by a helper that other tests can reach. Both work today only because tests run sequentially and
each uses a fresh temporary directory, so the coupling is invisible in the test body and an
ordering change or a new test sharing a directory becomes a failure with no relationship to the
change. Windtrap ships `bracket` (per-test setup/teardown) and `fixture` (lazy shared resource) for
exactly this; the CLI suite uses neither.

## Desired invariant

A test's fixture is owned by that test, or explicitly shared with a declared lifetime. No test
reads state another test wrote without that sharing being visible at the read site.

## Remediation

Make the target-file fixture per-test state (thread it through, or wrap each test in Windtrap's
`bracket`), and thread the Postgres pool through the helper that needs it instead of a module-level
`ref`. Where a suite genuinely needs one expensive shared resource, use Windtrap's `fixture` so its
lifetime is declared rather than ambient.

## Acceptance criteria

- No module-level mutable value exists in a test module or test-support library.
- The target-file fixture's state is visibly scoped to one test (or to a declared `fixture`).
- The Postgres suite's reclaim helper receives its pool rather than reading a module-level `ref`.
- Demo/example: not applicable — test-only change. Language parity: no application-facing contract
  change; state that in one line.
