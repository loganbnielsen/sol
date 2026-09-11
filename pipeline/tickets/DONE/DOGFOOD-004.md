---
id: DOGFOOD-004
type: feature
severity: high
source: product-planning-2026-06-11
branch: DOGFOOD-004/ops-loop
worktree: /home/lbendtly/Code/sun-DOGFOOD-004-ops-loop
---

Operations loop dogfood: secrets, migrations, logs, rollback.

**Depends on:** DOGFOOD-003.

**Problem:** Day-2 operations are part of Sun's value. A deploy that works only
until the first secret, migration, bad release, or debugging session is not a
credible production platform.

**Goal:** Exercise the core operations commands end to end on the dogfood
workspace.

**Remediation:**

1. Use `sun secret set/list/delete` against the local/customer-cloud target.
2. Run `sun migrate` and confirm migration tracking is workspace-isolated.
3. Use `sun logs` to inspect service and worker output.
4. Deploy a known-bad change and confirm failure visibility.
5. Run `sun rollback` and confirm the previous release is restored or that the
   unsupported case fails clearly.
6. Record UX gaps and unclear error messages as follow-up tickets.

**Acceptance criteria:**

- Secrets are materialized without printing values.
- Migrations apply once and report status clearly.
- Logs are discoverable from the CLI.
- Rollback behavior is either functional or explicitly bounded with actionable
  errors.
