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
