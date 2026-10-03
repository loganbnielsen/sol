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

**Premise re-verified (2026-10-02)** against `origin/main @ f7d45074`: the `(copy …)`
rule was still in `framework/ocaml/sol-svc/test/dune` and `test_auth.ml` still
called `Test_auth_internal`.

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

## Completion (2026-10-02)

Implemented on `VERIF-018/auth-service-boundary`.

- `framework/ocaml/sol-svc/test/dune` has no `(copy …)` rule and no
  `test_auth_internal.ml`; the test set is the four real executables.
- `test_auth.ml` is rewritten to drive `Service.For_testing.dispatch` with a
  route whose `~auth` is the level under test and a handler that echoes the
  resolved principal, so every assertion is the externally observable HTTP
  status (200/401/403/500) and, on success, the principal the service produced.
  All 37 cases pass. The two cases that assert identical behaviour were merged.
- The only direct coverage through a named seam is the pure
  `Auth.For_testing.constant_time_equal`, which is the function production uses.
  The JWKS cache moved to the private `auth_cache` module so `Auth` can expose
  `For_testing.seed_stale_jwks_cache`/`reset_jwks_cache`; the two wall-clock cache
  cases still assert at the boundary and use that control only to age the cache.
  `Service.For_testing.dispatch` gained `?read_api_key` so the API-key branches
  are exercised through the service rather than a hand-built call.
- `check_test_reachability.py` still passes; the removed copy target was a build
  artifact, never under its `cli/test` root, so no re-scope was needed.
- Checks: `test_auth` 37/37, `test_service` 33/33, `test_routing` 15/15,
  `test_peer` 5/5, `check_test_reachability.py`, `check_no_comments.sh`,
  `check_ocamlformat.sh --staged`.
- Demo/example: not applicable — test-only change. Language parity (DEC-022): the
  auth contract is unchanged; no application-facing surface changed.
