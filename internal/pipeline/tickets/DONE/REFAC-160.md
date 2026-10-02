---
id: REFAC-160
type: refactor
severity: medium
title: Migrate the CLI test suite to Windtrap inline tests
source: PR 743 Batch 0 architecture and internal/specs/cli-test-migration.md
---

**Depends on:** None.

**Premise verified 2026-10-02** against `origin/main @ 38d0a43f`: PR 743
installed `cli/test/inline/`, the Windtrap dependencies and the reachability
guard, but moved no existing tests. `internal/specs/cli-test-migration.md` still
lists the ordinary CLI tests as `legacy`, and `cli/test/dune` still registers
them in a shared `(tests (names ...))` stanza.

**Premise re-verified this session**: `cli/test/dune` named 89 modules in the
shared `(tests (names ...))` stanza and registered five more in separate
`(test ...)` stanzas, and `cli/test/inline/` held only `cli_binary.ml`.

## Remediation

Migrate the ordinary `cli/test/` modules to `cli/test/inline/` using the
architecture in `internal/specs/cli-test-architecture.md`. Keep each module's
behavioral assertions and isolation, remove its name from the legacy Dune
registry when moved, and update the migration table in the same change.
Retain an explicit executable only for the process semantics listed in that
architecture, recording the reason in the table. Finish by removing the empty
legacy registry and any migration-only scaffolding that no longer serves a
purpose. Keep the reachability guard.

The work may be split into reviewable PRs, but this ticket is complete only
when every module is either inline or a justified explicit executable.

## Acceptance criteria

- No ordinary CLI test depends on the shared `(tests (names ...))` registry.
- Every test module is reachable and runs under `dune test cli/test`; the
  reachability guard and its mutation cases pass.
- The migration table accounts for every module and records reasons for the
  remaining explicit executables.
- The CLI test suite passes with the migrated tests, including binary-driven
  tests that need the built `sol` executable.
- Demo/example: not applicable; this is internal test architecture.
- Language parity: no application-facing contract changes.

## Completion notes

The migration is complete. All 94 ordinary modules are either inline (93) or a
justified explicit executable (`test_supervised`), and `cli/test/dune` no longer
has a `(tests (names ...))` registry. The migration table in
`internal/specs/cli-test-migration.md` accounts for every `cli/test/*.ml` module
and records the reason for each of the three retained executables.

Checked this session:

- `dune test cli/test/` exits 0: 93 inline partitions, 1537 `let%test` cases,
  the retained executables and the shell rules.
- `internal/ci/check_test_reachability.py cli/test` and
  `internal/ci/test_test_reachability.sh` pass.
- `internal/ci/check_ocamlformat.sh --all` is clean.

The moved modules keep their assertions unchanged (`Alcotest.check` and friends)
and only their registration changed, so the per-case checks still run; the
`let%test` count matches the old suite's test count. The two shared path helpers
`cli/test/inline/cli_binary.ml` and `cli/test/support/source_root.ml` replace the
old `Sys.executable_name` arithmetic and the hard-coded `../../../../` walk, and
the inline library declares the `examples/pluto` and `platform/cloud` fixtures as
deps rather than reaching out of `_build`.

Hurdle: `test_supervised.ml` stayed an executable. It forks, calls `setsid`, and
supervises a child process group, and under the inline runner its provider never
started; the architecture's "owns a process-level lifecycle" case is why it is
retained rather than converted.

Demo/example: not applicable; internal test architecture. Language parity: no
application-facing contract changes.
