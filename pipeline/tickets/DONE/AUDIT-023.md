---
id: AUDIT-023
type: audit-finding
severity: low
source: project/audits/2026-06-11_audit.md
branch: AUDIT-023/migrate-dry-run
worktree: ../sun-AUDIT-023-migrate-dry-run
---

`sun migrate` missing `--dry-run` flag

**Depends on:** None.

**Description:** The audit runbook invariant requires "sun migrate --dry-run prints the SQL before touching the database." No such flag exists in `cli/sun/bin/cmd_migrate.ml` or the underlying `Migration.apply` in `integrations/storage/sun-storage/lib/migration.ml`.

**Impact:** Operators cannot preview migration SQL before applying to a live database. Risky for production migrations with additive/destructive changes.

**Remediation:** Add `--dry-run` flag to the `apply` subcommand (and the default subcommand path) that reads pending migration files and prints each SQL statement to stdout without executing them against the database.

## Review — automated checks passed
--dry-run flag added to apply_cmd and the default Term; print_pending_sql reads .sql files (excluding .down.sql), prints headers and content; no DB connection in dry_run path.
