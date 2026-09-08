---
id: FEAT-023
type: feature
severity: low
source: docs/planning/POST_DOGFOOD_GAMEPLAN.md
branch: FEAT-023/logs-grafana-pointer
worktree: /home/lbendtly/Code/sun-FEAT-023-logs-grafana-pointer
---

Point `sun logs` users to Loki-backed Grafana views when stdout is incomplete.

**Depends on:** DOGFOOD-004.

**Problem:** `sun logs` can show recent stdout from Kubernetes, but dogfood found
that complete Loki-routed log history still requires opening Grafana and knowing
the correct LogQL query.

**Goal:** Keep `sun logs` useful as the first incident command by printing a
ready-to-open Grafana Explore URL for the selected service/domain.

**V1 decision:** `sun logs` prints a URL; it does not open a browser and it does
not query Loki directly. The existing `kubectl logs` behavior remains the
primary output. The Grafana URL is supplemental incident context.

**Remediation:**

1. Derive workspace, domain, and service labels from the same naming model used
   by deployment.
2. Generate the LogQL query for the selected target.
3. Add a small pure helper for Grafana Explore URL generation so tests do not
   need a cluster.
4. Print the Grafana URL after the target is resolved, before invoking
   `kubectl logs`.
5. Support an optional `--grafana-base-url` flag, defaulting to
   `http://localhost:3000` for local dev.
6. Document the behavior in README and tutorial.
7. Add tests for URL/query generation.

**Out of scope:**

- Opening the browser automatically.
- Querying Loki directly from the CLI.
- Historical log pagination.
- Trace-centric log navigation.

**Acceptance criteria:**

- `sun logs payments/charge_svc` prints a copyable Grafana Explore URL.
- The query filters to the selected service and remains stable across workspaces.
- Existing stdout log behavior is unchanged.
