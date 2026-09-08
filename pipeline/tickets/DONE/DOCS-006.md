---
id: DOCS-006
type: docs-finding
severity: high
source: project/audits/2026-06-22_docs_audit.md
branch: DOCS-006/migration-rollback-undoc
worktree: ../sun-DOCS-006-migration-rollback-undoc
---

`sun-storage.md` says migration rollback is out-of-scope; `Migration.rollback` is fully implemented

**Description:** `integrations/storage/sun-storage/sun-storage.md` contains an "Out of Scope" note stating "programmatic rollback — migrations are one-directional in v1; down-migrations are manual SQL." `Migration.rollback` is fully implemented in `sun-storage/lib/migration.mli` with signature `val rollback : ?table:string -> Db.pool -> dir:string -> (unit, Storage_error.t) result` and is exposed by `sun migrate rollback` in the CLI.

The spec also does not mention the `?table:string` optional parameter on `apply`, `status`, or `rollback`, even though the Tutorial (Part 4) correctly documents the workspace-prefixed default table name.

**Impact:** Users reading the spec believe they must write manual SQL for down-migrations. The `sun migrate rollback` command and `Migration.rollback` function go undiscovered.

**Remediation:**
1. Remove the "Out of Scope / one-directional in v1" note.
2. Add `Migration.rollback` to the spec's API table with its signature.
3. Add a note explaining the `?table` parameter on all three functions and how it relates to the CLI's workspace-prefixed default.

## Review — automated checks passed
All remediation items implemented correctly: rollback removed from Out of Scope, sun migrate CLI removed from Out of Scope, rollback documented with correct signature, ~table documented on apply/status/rollback, workspace-isolation use case explained, sun migrate CLI table naming relationship noted, project/tickets/ untouched.
