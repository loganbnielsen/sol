---
id: AUDIT-048
type: audit-finding
severity: high
source: codebase review 2026-06-14
branch: AUDIT-048/e2e-golden-workflow-tests
worktree: /home/lbendtly/Code/sun-AUDIT-048-e2e-golden-workflow-tests
---

Promote the local demo into a real end-to-end test suite with explicit assertions

**Depends on:** None.

**Description:** `platform/local/scripts/run_tests.sh` defines the `e2e` suite by shelling out to:

```bash
dune exec examples/local-demo/bin/demo.exe
```

The demo binary exercises useful behavior, but it is not a dune/Alcotest test target and does not produce granular test cases for the core golden workflow. Failures collapse into a single executable failure, and `dune test` does not discover the end-to-end contract directly.

**Impact:** The highest-value user path can regress without a clear failing test name: service request handling, Kafka publish/consume, worker acking, Postgres persistence, metrics, and trace propagation are all coupled inside a demo program. This also makes it harder to run or extend one e2e assertion at a time.

**Remediation:**

1. Add an `examples/local-demo/test/` dune test target using Alcotest.
2. Extract reusable setup/helpers from `examples/local-demo/bin/demo.ml` into library code where needed, leaving the demo as a thin executable.
3. Assert the golden path explicitly:
   - service health responds;
   - POSTing orders publishes Kafka messages;
   - worker consumes and persists all expected rows;
   - metrics counters become non-zero;
   - trace context is propagated from service to worker.
4. Update `run_tests.sh` so `run_e2e` calls `dune test examples/local-demo/test/ --force` or an alias that runs the new tests.
5. Keep the human-readable demo executable available for dogfooding, but do not rely on it as the only e2e gate.

**Acceptance criteria:**

- `dune test examples/local-demo/test/ --force` runs the end-to-end golden workflow against local Kafka/Postgres/Loki dependencies.
- `./platform/local/scripts/run_tests.sh e2e` runs the new e2e test target and reports named test failures.
- The old demo still builds and can still be run manually.
- The new tests fail if worker persistence, Kafka consumption, or service request handling is broken.

## Review — automated checks passed
All 5 acceptance criteria met: test file exists with 5 Alcotest test cases, dune registers test_e2e, run_e2e() calls dune test (not dune exec), demo and retry_demo still build, project/tickets/ untouched
