---
id: DOGFOOD-002
type: feature
severity: high
source: product-planning-2026-06-11
branch: DOGFOOD-002/local-dev-lifecycle
worktree: /home/lbendtly/Code/sun-DOGFOOD-002-local-dev-lifecycle
---

Local dev lifecycle dogfood.

**Depends on:** DOGFOOD-001.

**Problem:** The local developer loop is Sun's foundation. If `sun dev up`,
`sun dev run`, and local observability are flaky, hosted work will hide core
workflow problems instead of solving them.

**Goal:** Prove the local development loop on a fresh generated workspace.

**Remediation:**

1. From the workspace created in DOGFOOD-001, run `sun dev up`.
2. Verify Kafka, schema registry, Postgres, Loki, Grafana, and Pushgateway
   endpoints.
3. Run `sun dev run` and confirm service/worker processes start with the
   expected local environment variables.
4. Exercise at least one service request and one worker/event path.
5. Run `sun dev status` and `sun logs`.
6. Run teardown/restart and confirm the loop is repeatable.

**Acceptance criteria:**

- Local infrastructure starts from a clean state.
- Application processes run without hand-edited environment variables.
- Logs and status commands provide enough information to debug failures.
- Repeat start/stop does not leave stale port-forwards or misleading success
  output.
