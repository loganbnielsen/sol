---
id: DOCS-001
type: docs-finding
severity: medium
source: project/audits/2026-06-12_docs_audit.md
branch: DOCS-001/migration-tracking-docs
worktree: ../sun-DOCS-001-migration-tracking-docs
---

Update migration tracking docs to match the CLI's workspace-prefixed default.

**Depends on:** None.

**Problem:** `docs/guides/TUTORIAL.md` still says `sun migrate` records applied
versions in `sun_schema_migrations`. The current CLI derives a workspace-prefixed
default table, for example `sun_dogfood_2026_06_12_schema_migrations`, and
`sun migrate --help` documents that behavior. The low-level storage library
still defaults to `sun_schema_migrations`, but the user-facing CLI does not.

**Goal:** Make user-facing migration docs match the command users actually run.

**Remediation:**

1. Update Tutorial Part 5 to say `sun migrate` records applied versions in
   `sun_<workspace>_schema_migrations` by default.
2. Mention that `--table` overrides the default when an operator intentionally
   wants a custom/shared tracking table.
3. Keep `sun_schema_migrations` references only where they describe the
   low-level `Sun.Storage.Migration` library default, or explicitly distinguish
   that library default from the CLI default.
4. Optionally update `docs/audits/AUDIT.md` so future auditors query the
   workspace-prefixed table instead of `sun_schema_migrations`.

**Acceptance criteria:**

- `docs/guides/TUTORIAL.md` no longer claims the CLI default is
  `sun_schema_migrations`.
- A user following the Tutorial can inspect the correct migration table name
  after running `sun migrate`.
- Low-level package docs remain accurate about `Migration.apply`'s library
  default.

