---
id: AUDIT-059
type: audit-finding
severity: medium
source: codebase review 2026-06-14
branch: AUDIT-059/control-plane-postgres-tests
worktree: /home/lbendtly/Code/sun-AUDIT-059-control-plane-postgres-tests
---

Turn the Postgres-backed control-plane registry tests from stubs into real integration tests

**Depends on:** None.

**Description:** `cli/sun/test/test_pg_registry.ml` has a `pg_ops (integration)` section, but the Postgres tests still skip even when `CONTROL_PLANE_TEST_DATABASE_URL` is set. The file documents intent but does not create a pool, call `Pg_registry.ensure_schema`, or exercise the Postgres registry operations.

**Impact:** The in-memory registry vtable is tested, but the Postgres implementation can drift in schema, query behavior, pagination, digest updates, status updates, and log retrieval without automated coverage. This is a direct gap in hosted/control-plane persistence confidence.

**Remediation:**

1. Expose the Postgres registry implementation from a testable library module rather than keeping it embedded only in `cmd_cloud.ml`.
2. When `CONTROL_PLANE_TEST_DATABASE_URL` is set, create an isolated schema or uniquely prefixed test rows.
3. Exercise create project, create release, list releases, pagination, logs, digest updates, status updates, and service rows through the same `registry_ops` interface.
4. Clean up test data after each run or use transaction rollback where practical.

**Acceptance criteria:**

- With `CONTROL_PLANE_TEST_DATABASE_URL` set, `dune test cli/sun/test/ --force` executes real Postgres registry operations.
- Without the env var, tests still skip clearly.
- The Postgres and memory implementations pass the same behavioral test suite where applicable.
- Registry schema/query drift is caught by tests.

## Review — automated checks passed
AUDIT-059 is clean and ready to merge. Build succeeds, all 19 tests pass (11 memory tests always pass; 8 pg_ops integration tests run against a live DB when CONTROL_PLANE_TEST_DATABASE_URL is set and skip when not). sun_cli_pg_registry.ml exists with ensure_schema/pg_ops/delete_project_rows exported; cmd_cloud.ml carries only module Pg_registry = Sun_cli_pg_registry with no inline implementation; (wrapped false) preserved; project/tickets/ not in diff.
