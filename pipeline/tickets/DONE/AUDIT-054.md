---
id: AUDIT-054
type: audit-finding
severity: high
source: codebase review 2026-06-14
branch: AUDIT-054/scaffold-schema-test-runtest
worktree: /home/lbendtly/Code/sun-AUDIT-054-scaffold-schema-test-runtest
---

Make generated schema compatibility checks run under `dune runtest`

**Depends on:** None.

**Description:** `cli/sun/lib/sun_cli_cmd_new.ml` generates `test/test_schemas.ml` as a schema compatibility gate, but its `test/dune` template is:

```lisp
(executable
 (name test_schemas)
 ...)
```

A plain dune executable is built when targeted directly, but it is not a test stanza and is not run by `dune runtest`. The generated CI workflow calls `dune runtest`, so the intended schema compatibility gate can be silently skipped.

**Impact:** Generated workspaces appear to have a schema CI gate, but the gate is not executed by the default generated CI command. Kafka schema compatibility can regress while CI stays green.

**Remediation:**

1. Change the generated `test/dune` template to use `(test (name test_schemas) ...)`, or add an explicit runtest alias that executes the binary.
2. Add scaffold tests that inspect generated `test/dune` and verify it is runnable by `dune runtest`.
3. In a temporary generated workspace, run `dune runtest` with no `SCHEMA_REGISTRY_URL` and verify the schema test is discovered and reports the documented skip.
4. If live registry tests are required in CI, document the env var and make the skip explicit in the test output.

**Acceptance criteria:**

- Generated `test/test_schemas.ml` runs under `dune runtest`.
- Generated `sun-ci.yml` continues to use `dune runtest`, and that command covers the schema gate.
- Scaffold tests fail if `test/dune` regresses back to a non-runtest executable.
- The no-registry path remains a clean, visible skip rather than a hidden non-run.

## Review — automated checks passed
AUDIT-054 correctly changes the scaffold test/dune template from (executable to (test stanza. Build succeeds with no errors. All 29 tests pass, including 2 new schema_test_dune cases that assert (test stanza is present and (executable is absent. project/tickets/ is untouched in the worktree. No violations found.
