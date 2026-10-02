---
id: VERIF-018
type: refactor
severity: medium
title: 'The auth suite tests a build-time copy of a private module, not the service contract'
source: internal/pipeline/audits/2026-10-02_test_suite_audit.md
premise: '! rg -q -F "(copy %{deps} %{target})" framework/ocaml/sol-svc/test/dune'
---

The auth suite tests a build-time copy of a private module, not the service contract

**Depends on:** None.

**Premise verified (2026-10-02)** against `origin/main @ 310917dd`:
`framework/ocaml/sol-svc/test/dune:1-6`:

```lisp
(rule
 (target test_auth_internal.ml)
 (deps ../lib/auth_internal.ml)
 (action
  (copy %{deps} %{target})))
```

`test_auth.ml` then calls `Test_auth_internal.validate` / `constant_time_equal` directly (`:7`,
`:14`). `framework/ocaml/sol-svc/lib/dune` declares `(private_modules auth_internal route_internal)`,
which is why the copy exists.

## Problem

`auth_internal` is private to `sol_svc`, so the test cannot link it by name and Dune re-copies the
source on every build — the copy stays in sync, so this is not drift. The cost is that production
logic is compiled a second time under a test-only module name, and that the assertions bind to an
internal function surface rather than to the `Service` contract the module exists to implement. A
refactor that preserves observable auth behaviour but reshapes a helper breaks the suite without a
contract change, and a regression the HTTP layer would expose can stay invisible when the helper is
called with hand-built inputs. Some direct helper coverage — `constant_time_equal` in particular —
is legitimate; the copy mechanism is the part to remove. `Worker.For_testing`,
`Service.For_testing`, `Sol_outbox.For_testing` and `Sol_jobs.For_testing` are the sanctioned shape
of the same seam.

## Desired invariant

A library test exercises the library's declared boundary. Where a pure internal function genuinely
needs direct coverage, the library exposes it deliberately through one named `For_testing` module
rather than having the test compile its own copy.

## Remediation

Move the auth assertions onto the `Service` boundary — a real request against the in-process server
that `test_service.ml` already runs — and add the helpers that genuinely need direct coverage
(`constant_time_equal` and friends) to an `Auth.For_testing` module in the library. Delete the
`(copy …)` rule and `test_auth_internal.ml`. Re-scope
`internal/ci/check_test_reachability.py` accordingly, as `cli-test-architecture.md` already plans.

## Acceptance criteria

- `framework/ocaml/sol-svc/test/dune` has no `(copy …)` rule and no `test_auth_internal.ml` target.
- The auth contract is asserted at the `Service`/HTTP boundary; only genuinely pure helpers are
  asserted through a named `For_testing` module.
- `check_test_reachability.py` still passes over its (possibly re-scoped) root.
- Demo/example: not applicable — test-only change. Language parity: the auth contract itself is
  unchanged; state that in one line.
