---
id: VERIF-014
type: bug
severity: high
title: 'The shipped sol_jobs migrations are stale, and every DB fixture hand-rolls the schema'
source: internal/pipeline/audits/2026-10-02_test_suite_audit.md
premise: 'rg -q workspace internal/fixtures/local-demo/migrations/0002_sol_jobs.sql && rg -q workspace examples/pluto/db/migrations/0002_sol_jobs.sql && rg -q workspace internal/fixtures/venus/db/migrations/0002_sol_jobs.sql'
---

The shipped `sol_jobs` migrations are stale, and every DB fixture hand-rolls the schema

**Depends on:** None.

**Premise verified (2026-10-02)** against `origin/main @ 310917dd`:

```
$ for f in internal/fixtures/local-demo/migrations/0002_sol_jobs.sql \
           examples/pluto/db/migrations/0002_sol_jobs.sql \
           internal/fixtures/venus/db/migrations/0002_sol_jobs.sql; do
    printf '%s: ' "$f"; rg -q workspace "$f" && echo "HAS workspace" || echo "MISSING workspace"
  done
internal/fixtures/local-demo/migrations/0002_sol_jobs.sql: MISSING workspace
examples/pluto/db/migrations/0002_sol_jobs.sql: MISSING workspace
internal/fixtures/venus/db/migrations/0002_sol_jobs.sql: MISSING workspace
```

`sol-jobs` requires `workspace` as a row identity (`framework/ocaml/sol-jobs/lib/sol_jobs.ml:174`
is `AND workspace = ?`; `sol-jobs.md` § *Job table* gives the canonical DDL and the
`(workspace, kind, dedupe_key)` dedupe index). `internal/fixtures/local-demo/bin/demo.ml:256`
applies `internal/fixtures/local-demo/migrations/` and then, at `:281`, constructs
`Sol_jobs.Make (EmailJob)`; `examples/pluto` and `internal/fixtures/venus` do the same from their own
migration directories. So a workspace that applies a shipped migration and then runs `sol-jobs`
fails with `column "workspace" does not exist`.

No test reports it because every DB fixture declares the schema itself, with `workspace`: the
E2E fixture at `internal/fixtures/local-demo/test/test_e2e.ml:165-183`, and the two library suites
at `framework/ocaml/sol-jobs/test/test_sol_jobs_pg.ml:3-23` and
`framework/ocaml/sol-outbox/test/test_sol_outbox.ml:11-42`. The E2E suite never runs a migration
file at all. The fixture and the artifact disagree, and the test asserts against the fixture.

## Problem

The fixture is not the artifact, so the artifact is unverified. The `sol_jobs` schema is written in
six places — `sol-jobs.md`, the three app migrations, and the three test fixtures — and the app
migrations have already drifted two changes behind the library. This is the same class as BUG-115
(a fixture describing a stale job table), caught one layer further out: BUG-115 fixed the fixture
against the library, but nothing makes the *migrations* agree with either.

## Desired invariant

A DB suite's schema comes from the migration artifact the app ships, so a stale migration fails the
suite that claims to exercise that schema. `sol-jobs` deliberately has no migration of its own, so
the source for a fixture is the app migration directory (for E2E: `internal/fixtures/local-demo/migrations/`).

## Remediation

Correct `internal/fixtures/local-demo/migrations/0002_sol_jobs.sql`,
`examples/pluto/db/migrations/0002_sol_jobs.sql` and
`internal/fixtures/venus/db/migrations/0002_sol_jobs.sql` to the canonical shape (add `workspace`,
`dedupe_key`, `finished_at`, and the `(workspace, run_at)` / `(workspace, kind, dedupe_key)` indexes),
and make `internal/fixtures/local-demo/migrations/0003_sol_jobs_dedupe.sql` idempotent and
workspace-scoped. Then replace `test_e2e.ml`'s `fixture_ddl`/`ensure_schema` with
`Migration.apply` over the real migration directory (adding the directory as a Dune dependency). The
two library suites' own copies are left to `VERIF-007`, which already restructures those files.

## Acceptance criteria

- The three `sol_jobs` migrations contain `workspace` and the workspace-scoped dedupe index, and a
  workspace that applies them can run `Sol_jobs.Make` against the result.
- `test_e2e.ml` obtains its schema by applying `internal/fixtures/local-demo/migrations/`; it
  contains no inline `CREATE TABLE sol_jobs`/`sol_outbox`.
- The library suites keep their own schema definitions for now; `VERIF-007` owns unifying them and
  their object ownership.
- Demo/example: this *is* the example fix — `demo.exe`, `examples/pluto` and `internal/fixtures/venus`
  migrations become correct.
- Language parity: no application-facing contract change; the migration is SQL shared by both
  languages. State that in one line in the completion notes.

## Completion (2026-10-02)

Implemented on `VERIF-014/shipped-migrations`:

- `internal/fixtures/local-demo/migrations/0002_sol_jobs.sql`,
  `examples/pluto/db/migrations/0002_sol_jobs.sql` and
  `internal/fixtures/venus/db/migrations/0002_sol_jobs.sql` now carry the canonical
  `workspace`/`dedupe_key`/`finished_at` table and the `(workspace, run_at)` and
  `(workspace, kind, dedupe_key)` indexes; `0003_sol_jobs_dedupe.sql` is idempotent and
  workspace-scoped.
- `internal/fixtures/local-demo/test/test_e2e.ml` drops `fixture_ddl`/`ensure_schema`'s ten inline
  DDL statements and applies `../migrations` through `Migration.apply`; `test/dune` declares the
  migration directory as a `(source_tree …)` dependency.
- Checks: `dune build internal/fixtures/local-demo/test/` and `cli/bin/main.exe` succeed; `git diff`
  confirms no inline `CREATE TABLE sol_jobs`/`sol_outbox` remains in the E2E suite. The DB-backed
  suite itself cannot run on this machine (no Postgres and no Docker), so its execution is verified
  by required CI, which provisions `sol_dev`.
- Demo/example: the three migrations above are the demo/example artifacts, now correct.
- Language parity: no application-facing contract change; the migration is the SQL both languages
  share. The TypeScript demo consumes the same table.
- Remaining: the two library suites still declare their own `sol_jobs`/`sol_outbox` schema;
  unifying those definitions and their object ownership is `VERIF-007`.
