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
