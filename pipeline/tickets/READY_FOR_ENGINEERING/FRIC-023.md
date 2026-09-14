---
id: FRIC-023
type: dogfood-finding
severity: medium
source: pipeline/dogfood/RUN_2026-09-13.md
---

**Depends on:** None.

App/worker logs never reach stdout, so the runbook's `kubectl logs` diagnostic is empty

**Description:** The generated worker calls `Sol_obs.log_info "charge event received"` (`cli/sol/lib/sol_cli_scaffold_templates.ml`, the `notify_worker.ml` template). After a successful POST/consume/write, `kubectl logs -n <ws>-comms deploy/notify-worker --tail=20` returns nothing (both deployed workspaces, no restarts). The line *is* delivered to Loki — querying `{service=~".*notify.*"}` returns:

```
level=info msg="charge event received" span=log charge_id=ch_770445 customer_id=cus_exp2
  amount_cents=123 trace_id=... span_id=...
```

so logs are being pushed directly to Loki and not written to stdout. `docs/dogfood/DOGFOOD.md`'s "Useful Diagnostics" section recommends exactly `kubectl logs ... deploy/notify-worker`.

**Impact:** The primary documented debugging path for a Kafka worker yields nothing. A user debugging the event path concludes logging is broken (or that the worker never ran) and has to discover the Loki path on their own — even though the log line is present and well-labelled.

**Remediation:** Either make services echo structured logs to stdout as well as pushing to Loki (arguably "dev mirrors prod" and `kubectl logs` working is table stakes), or replace the runbook diagnostics with `sol open logs` / the Loki query and state explicitly that app logs go to Loki, not container stdout. If the latter, name the label to filter on (`{service=~"..."}`).

Related: OBS-* (observability pipeline), FRIC-024 (observability status is already surfaced by `sol local status`).
