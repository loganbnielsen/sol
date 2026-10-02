---
id: REFAC-174
type: refactor
severity: medium
title: Migrate the scaffold workspace template suite to Windtrap
source: internal/specs/cli-test-architecture.md; REFAC-160 established the pattern for cli/test
---

Migrate the scaffold workspace template suite to Windtrap

**Depends on:** None.

**Related:** None. The verification boundary is `cli/test/inline/test_scaffold.ml`, which renders the template and runs its suite.

**Premise (2026-10-02, `origin/main @ 8a4cdacd`):** `platform/shared/templates/workspace/test/dune` registers two `(test …)` stanzas rendered with `{{name}}` substitutions; `cli/test/inline/test_scaffold.ml` renders the workspace and runs its suite. Its assertions are
`Alcotest.*` and the stanza still lists `alcotest`. The suite is generated into every scaffolded workspace, so its dune is app-author-facing output, and it is exercised by rendering and running it rather than directly.

## Problem

Windtrap is the repository's test framework: `internal/specs/cli-test-architecture.md` states the
model, `REFAC-160` migrated `cli/test` to it and `REFAC-161` converts that suite's assertions off
`Alcotest`. scaffold workspace template is still a second convention, so the runner contract, the assertion vocabulary
and the fixture-lifetime helpers have to be understood and changed twice, and this suite does not
get Windtrap's per-module isolation, `bracket`/`fixture` lifetime helpers or mutation tooling.

## Desired invariant

scaffold workspace template discovers its cases through Windtrap and asserts through `Windtrap.equal`/`fail`/`failf`;
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

- Every module of the suite either runs under `dune test platform/shared/templates/workspace/test` through Windtrap registration, or is a
  retained executable recorded with its reason.
- No module of scaffold workspace template references `Alcotest`, and no dune stanza there lists `alcotest`.
- `dune test platform/shared/templates/workspace/test` passes with every case the suite had before the migration; none is dropped and none is
  rewritten to assert less.
- Demo/example: this changes what a scaffolded workspace ships, so the scaffolded `README.md`/dune must stay valid; the ticket must state how the rendered suite is verified (render and run, as `test_scaffold.ml` already does).
- Language parity (DEC-022): no application-facing contract changes; state it in one line.

## Completion notes
