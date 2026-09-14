---
id: FRIC-029
type: dogfood-finding
severity: high
source: pipeline/dogfood/RUN_2026-09-13.md (found while implementing FRIC-023)
---

**Depends on:** None.

`sol logs` / `sol local logs` Loki queries match no streams: the selector uses `app`/`namespace`, but Sol's app-pushed logs carry `service`/`team`

**Description:** `Sol_cli_loki.query_range_argv` and `Sol_cli_loki.query` build the LogQL selector `{namespace="%s",app="%s"}` (`cli/sol/lib/sol_cli_loki.ml:39` and `:241`). Observed live on the local substrate, **neither** Loki stream type carries an `app` label:

- **App-pushed stream** (obs-loki — where the actual application logs are): `{detected_level, service="dogfood_2026_09_13-notify-worker", service_name="dogfood_2026_09_13-notify-worker", team="comms"}`. No `namespace`, no `app`.
- **Alloy-scraped pod-stdout stream**: `{container, domain, instance, job, namespace, pod, primitive, release, service, service_name, workspace}`. Has `namespace`, no `app`.

So `sol local logs --scope comms/notify_worker --no-follow` printed `(no log lines found in Loki for notify_worker; showing Kubernetes logs)` even though the worker's `charge event received` line is present in Loki. `{namespace=...,app=...}` matches zero streams.

**Impact:** The user-facing "show me this service's logs" command silently finds nothing for exactly the logs Sol's own observability layer produces, then falls back to `kubectl logs` — which is also empty because app logs are not written to stdout (FRIC-023). Debugging the golden path's Kafka step looked like the worker had logged nothing at all, when in fact the line was in Loki with a `trace_id`.

**Remediation:** Align the selector with the emitted label vocabulary. App-pushed streams are keyed by `service` (`<workspace>_<domain>_<unit>`, e.g. `dogfood_2026_09_13-notify-worker`) and `team`; a local-backend selector such as `{service=~".*<unit>.*"}` would match. If `namespace` is required for cloud multi-tenancy, ensure the push path actually sets it (in `obs-loki-eio`/`obs-eio`, not this repo). Add a regression test that runs the selector against a fixture Loki response.

**Coordinate first:** FRIC-023 leaves open whether the long-term answer is mirroring app logs to stdout or remaining Loki-only. Settle that convention before changing the query so the two tickets don't pick opposite answers.

Related: FRIC-023 (the diagnostics this query backs), OBS-* (observability label vocabulary).
