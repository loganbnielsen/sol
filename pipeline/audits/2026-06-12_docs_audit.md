# Sun Documentation Truth Audit — 2026-06-12

**Template:** `docs/audits/DOCS_AUDIT.md`  
**Method:** Compared user-facing docs, package specs, and CLI behavior for commands exercised during the audit and dogfood pass.

## Checks

| Area | Result |
|------|--------|
| Documented `sun new workspace` path | PASS |
| Generated README command flow | PASS |
| `sun dev up`, `sun up`, `sun status`, `sun logs`, `sun rollback` command existence | PASS |
| Schema compatibility documentation | PASS, Tutorial now references generated `test/test_schemas.ml` and `Kafka_service.Schema.check_all` |
| `sun new event` existing-domain behavior | PASS, CLI patches `events/<team>/dune` |
| Migration tracking docs | FAIL |

## Findings

### [DOCS-001] — Tutorial documents the old migration tracking table name

* **Category:** Command Truth
* **Severity:** Medium
* **Location:** `docs/guides/TUTORIAL.md` line 283; `cli/sun/bin/cmd_migrate.ml` lines 1-15 and 157-166
* **Description:** The Tutorial says `sun migrate` records versions in `sun_schema_migrations`. The current CLI derives a workspace-prefixed default such as `sun_dogfood_2026_06_12_schema_migrations`, and `sun migrate --help` documents that as the default. The storage package still has a low-level library default of `sun_schema_migrations`, but the user-facing CLI no longer does.
* **Impact:** Users inspecting Postgres after following the Tutorial will look for the wrong table and may incorrectly conclude migrations did not run. The old table name also reintroduces confusion around the prior multi-workspace collision bug.
* **Remediation:** Update the Tutorial to describe the CLI default as `sun_<workspace>_schema_migrations`, note that `--table` can override it, and keep `sun_schema_migrations` only in low-level library docs where it remains accurate.

