---
id: AUDIT-042
type: audit-finding
severity: high
source: codebase review 2026-06-13
branch: AUDIT-042/automated-e2e-golden-path
worktree: /home/lbendtly/Code/sun-AUDIT-042-automated-e2e-golden-path
---

Automate the scaffold-to-running-app e2e path; current coverage relies on dogfood notes and a demo binary, not a committed golden-path harness

**Depends on:** None.

**Description:** The repo has strong unit coverage and several integration tests, but the product-critical user journey is not represented as an automated e2e test:

- `platform/local/scripts/run_tests.sh` has an `e2e` suite, but it runs `examples/local-demo/bin/demo.exe` against pre-existing localhost infra.
- `docs/dogfood/DOGFOOD.md` documents the true release-user path manually: build the current `sun`, create a fresh workspace, run `sun dev up`, `sun up`, `sun migrate`, `sun status`, exercise `/health`, post a charge, and verify the worker wrote the notification.
- The dogfood reports in `project/dogfood/` show this path repeatedly finds regressions, but those checks are not committed as a repeatable test with setup, assertions, cleanup, and CI/runtime gating.

**Impact:** Regressions in the highest-value path can land even when `dune runtest` and `platform/local/scripts/run_tests.sh e2e` pass. Examples include scaffold output drifting from the actual CLI, missing migrations, broken generated Dockerfiles, stale port-forward behavior, and deploy/migrate/status sequencing bugs. These are exactly the issues that cost new users time because they happen after the code has already compiled.

**Remediation:**

1. Add a committed e2e harness, e.g. `cli/sun/e2e/golden_path.sh`, that:
   - builds the local `sun` binary from `_build/default/cli/sun/bin/main.exe`;
   - creates a temp workspace with `sun new workspace`;
   - runs `sun dev up`;
   - runs `sun up`;
   - runs `sun migrate`;
   - asserts `sun status` reports the deployed service;
   - curls `/health`;
   - posts to `/charges`;
   - polls `/notifications` until the Kafka-to-worker-to-Postgres flow is visible;
   - tears down workspace-owned port-forwards and temp files.
2. Wire this harness into `platform/local/scripts/run_tests.sh e2e` or add a separate `golden-e2e` suite with a longer timeout. Keep the existing `examples/local-demo/bin/demo.exe` check if it still provides useful lower-level integration coverage.
3. Make the e2e test opt-in for ordinary local unit runs if needed, but make it easy for release and dogfood runs to invoke one command.
4. Record the expected infra prerequisites and failure diagnostics in the script itself so failures point at the broken stage rather than dumping raw `kubectl`/curl output.

**Acceptance criteria:**

- A clean temp workspace can be scaffolded, deployed, migrated, and smoke-tested by one committed command.
- The command fails non-zero if `/health`, charge submission, or notification persistence fails.
- `platform/local/scripts/run_tests.sh e2e` either runs the golden path directly or clearly delegates to it.
- The previous demo-only e2e path is no longer the only automated e2e signal.

## Review — returned for revision
- `platform/local/scripts/run_tests.sh:161` — run_golden-e2e references $REPO_ROOT inside the timeout subshell but REPO_ROOT is never exported. In the subshell, $REPO_ROOT is empty, so bash "$REPO_ROOT/cli/sun/e2e/golden_path.sh" becomes bash "/cli/sun/e2e/golden_path.sh" which does not exist. Fix: add `export REPO_ROOT` after it is set (around line 30), or inline the path computation inside run_golden-e2e using BASH_SOURCE.

## Review — automated checks passed
AUDIT-042 implements a complete golden-path e2e test harness with proper integration into the test runner, correct exit codes, and comprehensive infra prerequisite documentation.
