---
id: REFAC-161
type: refactor
severity: medium
title: 'Every test suite runs on Windtrap; Alcotest is gone'
source: operator direction (2026-10-02); internal/specs/cli-test-architecture.md
premise: '! rg -q Alcotest --glob "*.ml"'
---

Every test suite runs on Windtrap; Alcotest is gone

**Depends on:** None.

**Premise verified (2026-10-02)** against `origin/main @ 8a4cdacd`:
`rg -l 'Alcotest' --glob '*.ml'` lists 112 files. `Alcotest.run` appears in 15
executable suites; the 94 CLI inline modules already register with Windtrap
(`let%test`) but assert with `Alcotest.check`/`fail`/`failf`. `sol.opam` pins
`alcotest`, and `dune-project` declares `(alcotest :with-test)`.

## Problem

Windtrap is established (`REFAC-160`) and the CLI suite is *discovered* through
it, but Alcotest is still the assertion library everywhere and the runner for
every executable suite. Two test frameworks means two result formats, two
failure vocabularies, and two spellings of the same assertion, plus a dependency
that exists only because the migration stopped at discovery. The architecture
spec says Windtrap is the test framework while the tree says otherwise, so a
reader cannot tell which one a new test should use.

## Desired invariant

One test framework: Windtrap. Every suite — inline and executable — registers
*and* asserts with it, and `alcotest` is not a dependency anywhere.

## Remediation

Replace Alcotest assertions with Windtrap's typed ones: `Alcotest.(check T) "msg"
e a` becomes `Windtrap.equal T ~msg e a`, `Alcotest.fail`/`failf` become
`Windtrap.fail`/`failf`, `Alcotest.check_raises "msg" exn f` becomes
`Windtrap.raises ~msg exn f`, and a custom `Alcotest.testable pp eq` becomes
`Windtrap.testable ~pp ()`. Convert each `Alcotest.run` runner to `Windtrap.run`
with `Windtrap.group`/`Windtrap.test`, preserving `` `Slow `` cases as
`~tags:(Windtrap.Tag.speed Windtrap.Tag.Slow)`. Swap `alcotest` for `windtrap` in
every test dune, drop the `alcotest` pin from `sol.opam`, and replace
`(alcotest :with-test)` in `dune-project`. Update
`internal/specs/cli-test-architecture.md` and `cli-test-migration.md`.

## Acceptance criteria

- `rg 'Alcotest' --glob '*.ml'` finds nothing.
- No dune file links `alcotest`; neither `sol.opam` nor `dune-project` names it.
- Every executable suite still runs its full case list under `Windtrap.run`, and
  every inline suite still registers the same cases.
- `internal/specs/cli-test-architecture.md` describes Windtrap as the only test
  framework and shows the executable-suite shape.
- Demo/example: not applicable — test-only. Language parity: no application-facing
  contract change.

## Completion notes

Landed by PR #881's sibling implementation branch. 131 files changed across the
94 CLI inline modules, 19 executable suites and the dependency pins.

- Assertions: `Alcotest.(check T) "msg" e a` → `Windtrap.equal T ~msg e a`;
  `Alcotest.fail`/`failf` → `Windtrap.fail`/`failf`; `Alcotest.check_raises` →
  `Windtrap.raises ~msg`; the two custom `Alcotest.testable`s (`ticket_state`,
  `result_error ()`) and `sol_process`'s `of_pp` testable → `Windtrap.testable
  ~pp ()`. The `Alcotest.(check @@ option @@ pair int string)` helper in
  `test_migration.ml` was rewritten as an explicit `Windtrap.equal` function.
- Runners: 19 `Alcotest.run` blocks → `Windtrap.run` with
  `Windtrap.group`/`Windtrap.test`; the 14 `` `Slow `` cases carry
  `~tags:(Windtrap.Tag.speed Windtrap.Tag.Slow)`.
- Dependencies: `alcotest` → `windtrap` in 13 dune files (dropped, not replaced,
  in `cli/test/inline/dune`, which already linked Windtrap), removed from
  `sol.opam`, and `(alcotest :with-test)` in `dune-project` → `windtrap`.
- Docs: `internal/specs/cli-test-architecture.md` (now "Test architecture")
  describes Windtrap as the only framework and names the executable-suite shape;
  `cli-test-migration.md` records the assertion migration; `AGENTS.md` drops
  `alcotest` from the package list.
- Verified locally: `dune build`; 14 framework/tooling suite groups
  (`dune test …`, 0 failures, including `sol-svc` 33 and `soldev` 27);
  93 CLI inline groups (`dune build @cli/test/inline/runtest`); and
  `test_supervised` (8). The broker/Postgres-backed suites compile here and run
  in CI.

Demo/example: not applicable — test-only. Language parity: no application-facing
contract change.
