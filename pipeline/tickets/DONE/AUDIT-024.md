---
id: AUDIT-024
type: audit-finding
severity: medium
source: project/audits/2026-06-11_audit.md
branch: AUDIT-024/workspace-prefixed-migration-table
worktree: ../sun-AUDIT-024-workspace-prefixed-migration-table
---

Migration tracking table is not workspace-prefixed

**Depends on:** None.

**Description:** The default migration tracking table is `sun_schema_migrations` for every workspace (`cli/sun/bin/cmd_migrate.ml` line 92). Two workspaces sharing a local Postgres instance (standard with `sun dev up`) share the same tracking table. Workspace A's migrations appear applied in workspace B, causing silent migration skips.

**Impact:** Incorrect `sun migrate status` output and missed migrations when multiple workspaces share a database.

**Remediation:** Derive the default table name from the workspace name found in the nearest `dune-project` file (e.g., `sun_<workspace>_schema_migrations`). Update `Migration.apply`, `Migration.status`, `Migration.rollback`, and `cmd_migrate.ml`. The `--table` flag override continues to work for advanced use.

## Review — automated checks passed
Build clean, diff limited to cmd_migrate.ml, default_table_name correctly derived from workspace directory with sanitization, table_arg updated, tests pass.
