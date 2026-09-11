---
id: DOGFOOD-009
type: bug
severity: high
source: dogfood/2026-06-11_DOGFOOD-002_local_dev_lifecycle.md
branch: DOGFOOD-009/loki-400-fix
worktree: /home/lbendtly/Code/sun-DOGFOOD-009-loki-400-fix
---

Investigate and fix Loki HTTP 400 from worker log shipper.

**Depends on:** None.

**Problem:** Deployed worker pods (`notify_worker`) emit only one log line:

```
[obs-loki] Loki returned HTTP 400
```

All application logs are silently dropped. `sun logs` shows only this error line, giving no visibility into what the worker is actually doing or why it may be failing.

**Goal:** Determine why Loki rejects logs from deployed workers and fix the log shipper configuration.

**Remediation:**

1. Retrieve the full HTTP 400 response body from Loki to see the error detail:
   - Add response body logging in `obs-eio-loki` when a non-200 status is received.
2. Likely causes:
   - Loki label format mismatch (labels must be `[a-zA-Z_][a-zA-Z0-9_]*`; hyphens in workspace/service names may be invalid)
   - Missing `X-Scope-OrgID` header (Loki multi-tenant mode)
   - Timestamp out of range (Loki rejects logs older than its ingestion window)
3. Fix the root cause and verify `sun logs` shows real application output.

**Acceptance criteria:**

- Worker log lines appear in `sun logs comms/notify_worker` output.
- No `[obs-loki] Loki returned HTTP 400` errors in pod logs.
- Grafana Loki datasource shows worker logs with correct labels.
