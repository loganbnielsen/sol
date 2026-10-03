---
id: VERIF-025
type: verification
severity: low
title: A verification case collapses "could not establish" into "observed nothing"
source: internal/pipeline/tickets/DONE/VERIF-006.md (PR #939 review, 2026-10-02)
---

A verification case collapses "could not establish" into "observed nothing"

**Depends on:** None.

Related: VERIF-006.

VERIF-006's `sol logs` case originally ended `| Error _ -> 0`, so a query that failed and a query
that succeeded with zero lines both produced the same "no pushed log lines" failure. The case now
keeps the final `fetch_error` and reports it. The same shape — an error folded into a count, a
`None`, or a `false` — recurs in the E2E fixture and in other suites.

## Problem

A red gate should distinguish "the contract was violated" from "the check could not observe the
contract". Collapsing them costs a re-run or a debugging session to tell which happened, and it is
cheap to avoid where the error is already in hand. It is the diagnostic half of the same principle
VERIF-006 applies to passing vacuously.

## Desired invariant

A verification case that fails names the cause it observed. Where a result carries both an error and
a neutral value, the case keeps the error and reports it rather than folding it into the neutral
value.

## Remediation

Start where the shape is concrete: `internal/fixtures/local-demo/test/test_e2e.ml`'s `db_rows`
(`| Error _ -> 0`) collapses "no Postgres pool" with "the query failed", and the fixture's other
`Error _ ->` / `| _ -> ()` sites are candidates. Then sweep `framework/ocaml/*/test` and `cli/test`
for the same shape — an absent dependency or a failed call folded into a neutral value that a later
`Windtrap` case cannot distinguish. Fix the cases where the distinction is real; where the neutral
value *is* the contract (a test that deliberately asserts absence), record that when completing the
ticket so the same sites are not re-examined next audit.

## Acceptance criteria

- A case that fails because its dependency could not be observed names the dependency or the error,
  not only that nothing was observed.
- The sweep's per-site outcome (fixed, or deliberately neutral with the reason) is recorded.
- Demo/example: not applicable — test and fixture code. Language parity (DEC-022): no
  application-facing contract change.

## Completion notes

Fixed 2026-10-02, `VERIF-025/report-the-cause`.

### The concrete site, fixed

`internal/fixtures/local-demo/test/test_e2e.ml` carried three folds, all fixed:

- `db_rows` was an `int` built with `| Error _ -> 0`, so "Postgres was not
  configured", "the query failed" and "zero rows stored" were one value. It is
  now `(int, string) result option`: `None` = Postgres not configured for this
  run, `Some (Error why)` = the read failed, `Some (Ok n)` = observed. The
  `postgres` and `jobs` cases match all three; the error case calls
  `Windtrap.failf "fulfilled_orders could not be read: %s"`, and only `None` and
  `Some (Ok 0)` keep the deliberate short-circuit (see below).
- The fixture's pool creation folded `| Error _ -> None` in both fixtures, so a
  configured-but-unusable Postgres looked like an absent one. Both now
  `failwith` with `Pg_error.to_string`; a misconfiguration is a broken run, not
  a degraded dependency (the same treatment `ensure_schema` already had).
- `truncate_tables` folded `| Error _ -> ()`. It returns `(unit, string) result`
  and both call sites fail with the cause — a failed truncate would have let
  stale rows flow into later assertions.

`cli/test/inline/test_terraform_plan.ml`'s `allowlist` dropped the parser's
message (`| Error _ -> Windtrap.fail "fixture is not valid plan JSON"`); it now
reports it (`the fixture plan could not be read: <msg>`).

### Evidence

Happy path, with real Kafka/Loki/Postgres (`dune build --force @ci-e2e`):
`All tests passed in 4ms. 19 tests run.`

Negative probe — the same binary driven with `POSTGRES_URL=nonsense`, which is
reachable from outside the suite:

```text
# before this change
› postgres
  PASS fulfilled orders persisted 807μs
All tests passed in 807μs. 19 tests run. (18 skipped)

# after
Fatal error: exception Failure("POSTGRES_URL is set but the fixture's pool could
not be created: connection failed: Cannot load driver for <nonsense>: Missing URI
scheme.")
```

A case named "fulfilled orders persisted" passed without Postgres ever being
reachable; it now refuses to run and names the cause.

### The sweep, per site

- `framework/ocaml/{sol-jobs,sol-outbox,sol-svc,sol-worker,kafka-eio-service}/test`,
  `cli/test/**`: **not the shape — no change.** The `| Error _ -> ()` sites are
  (a) assertions that an operation is *refused*, where the error *is* the
  expected outcome and a following state assertion carries the verdict
  (`sol_outbox`, `sol_jobs_pg`, `test_auth`, `test_loki`), (b) `Fun.protect
  ~finally` cleanup (`test_service`, `test_supervisor`), or (c) boolean
  predicates over a typed variant (`test_tool_adapters`). `Option.get` sites
  raise on `None`, so a missing value fails loudly rather than passing.
- `internal/fixtures/local-demo/test/test_e2e.ml` **deliberately neutral,
  recorded:** `None` (POSTGRES_URL unset) and `Some (Ok 0)` (nothing stored)
  still short-circuit the `postgres`/`jobs` cases. "The e2e class computes one
  shared fixture and short-circuits when it is degraded" is the design VERIF-015
  owns; this ticket separates only *could not observe* from *observed nothing*.
  The same applies to the outbox fixture's `empty_outbox_result`.
- `framework/ocaml/sol-jobs/test/test_sol_jobs_pg.ml` was being edited by
  VERIF-017 while this ran, so it was classified but not touched; its
  `Error _ -> ()` is the error-is-the-expected-outcome shape above.

No demo/example change: test and fixture code. No language-parity impact
(DEC-022).

