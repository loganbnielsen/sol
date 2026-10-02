---
id: REFAC-170
type: refactor
severity: medium
title: Migrate the local-demo e2e suite to Windtrap
source: internal/specs/cli-test-architecture.md; REFAC-160 established the pattern for cli/test
---

Migrate the local-demo e2e suite to Windtrap

**Depends on:** None.

**Related:** VERIF-002, VERIF-006, VERIF-014, VERIF-015 and VERIF-019 all restructure this suite. Its fixture model must settle first: migrating the discovery while the cases still short-circuit on a degraded fixture would preserve the defect in a new runner.

**Premise (2026-10-02, `origin/main @ 8a4cdacd`):** `internal/fixtures/local-demo/test/dune` registers `(tests (names test_e2e))`, one module that runs its whole fixture before the runner and is invoked with `--force` in CI. Its assertions are
`Alcotest.*` and the stanza still lists `alcotest`. `test_e2e.ml` computes one shared fixture before the runner and every case is conditional on it (VERIF-015), and its dependency comes from the ambient environment (VERIF-002).

## Problem

Windtrap is the repository's test framework: `internal/specs/cli-test-architecture.md` states the
model, `REFAC-160` migrated `cli/test` to it and `REFAC-161` converts that suite's assertions off
`Alcotest`. local-demo e2e is still a second convention, so the runner contract, the assertion vocabulary
and the fixture-lifetime helpers have to be understood and changed twice, and this suite does not
get Windtrap's per-module isolation, `bracket`/`fixture` lifetime helpers or mutation tooling.

## Desired invariant

local-demo e2e discovers its cases through Windtrap and asserts through `Windtrap.equal`/`fail`/`failf`;
no module in it references `Alcotest` and no stanza there lists `alcotest` as a library. A module
that genuinely needs its own process semantics stays an explicit executable, recorded with its
reason in `internal/specs/cli-test-migration.md` (extended to cover the whole repository, not only
`cli/test/`).

## Remediation

Move the discoverable modules into a Windtrap inline-test library in the suite directory
(`(inline_tests)` and `(preprocess (pps ppx_windtrap))`), wrapping each existing test function in a
`let%test` registration and keeping every case and its assertions. Convert `Alcotest.(check …)` /
`Alcotest.fail` / `Alcotest.failf` to `Windtrap.equal` (with the matching `Testable` constructor) /
`Windtrap.fail` / `Windtrap.failf`, then drop `alcotest` from the dune `libraries`. Retain an
explicit executable only for a module the architecture lists — its own `argv`, the test is the
process under test, it owns `Eio_main.run` or a comparable process-level lifecycle, or the
behaviour cannot be expressed faithfully under the inline runner — and drive that executable with
`Windtrap.run` so the assertion vocabulary stays single. Record every retained executable in
`internal/specs/cli-test-migration.md`.

## Acceptance criteria

- Every module of the suite either runs under `dune test internal/fixtures/local-demo/test` through Windtrap registration, or is a
  retained executable recorded with its reason.
- No module of local-demo e2e references `Alcotest`, and no dune stanza there lists `alcotest`.
- `dune test internal/fixtures/local-demo/test` passes with every case the suite had before the migration; none is dropped and none is
  rewritten to assert less.
- Demo/example: the E2E fixture *is* app-author-visible (it is the composed golden path); after migration `run_tests.sh e2e`/CI must still run the same composed path, and the ticket must say so.
- Language parity (DEC-022): no application-facing contract changes; state it in one line.

## Completion notes
