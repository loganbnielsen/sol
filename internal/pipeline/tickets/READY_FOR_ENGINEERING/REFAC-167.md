---
id: REFAC-167
type: refactor
severity: medium
title: Migrate the sol-jobs suite to Windtrap
source: internal/specs/cli-test-architecture.md; REFAC-160 established the pattern for cli/test
---

Migrate the sol-jobs suite to Windtrap

**Depends on:** None.

**Related:** VERIF-002 (dependency part of the target), VERIF-007 (per-suite schema ownership), VERIF-014 (apply the shipped migration instead of hand-rolled DDL) and VERIF-017 (the module-level `current_pool` ref). Migrating the pure module is independent of those; converting the Postgres module should follow them so it is not rewritten twice.

**Premise (2026-10-02, `origin/main @ 8a4cdacd`):** `framework/ocaml/sol-jobs/test/dune` registers `(test (name test_sol_jobs))` for the pure suite and an `(executable (name test_sol_jobs_pg))` behind the `runtest-integration` alias for the Postgres suite. Its assertions are
`Alcotest.*` and the stanza still lists `alcotest`. The Postgres module owns `Eio_main.run` and a connection pool (a retained-executable candidate), and VERIF-002/VERIF-007/VERIF-014 all change how it obtains its address, schema and objects.

## Problem

Windtrap is the repository's test framework: `internal/specs/cli-test-architecture.md` states the
model, `REFAC-160` migrated `cli/test` to it and `REFAC-161` converts that suite's assertions off
`Alcotest`. sol-jobs is still a second convention, so the runner contract, the assertion vocabulary
and the fixture-lifetime helpers have to be understood and changed twice, and this suite does not
get Windtrap's per-module isolation, `bracket`/`fixture` lifetime helpers or mutation tooling.

## Desired invariant

sol-jobs discovers its cases through Windtrap and asserts through `Windtrap.equal`/`fail`/`failf`;
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

- Every module of the suite either runs under `dune test framework/ocaml/sol-jobs/test` through Windtrap registration, or is a
  retained executable recorded with its reason.
- No module of sol-jobs references `Alcotest`, and no dune stanza there lists `alcotest`.
- `dune test framework/ocaml/sol-jobs/test` passes with every case the suite had before the migration; none is dropped and none is
  rewritten to assert less.
- Demo/example: not applicable — internal test architecture.
- Language parity (DEC-022): no application-facing contract changes; state it in one line.

## Completion notes
