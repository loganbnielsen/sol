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

## Completion notes

- Coordination check: FRIC-023 (`DONE`) settled the convention as Loki-only
  (app logs are not mirrored to stdout), with the runbook's verified-working
  query being `{service=~".*<unit>.*"}` — this ticket implements exactly that
  selector for `sol logs`/`sol local logs`.
- Changed `Sol_cli_loki.query_range_argv`/`.query` (`cli/sol/lib/sol_cli_loki.ml`)
  and `Sol_cli_logs.grafana_explore_url`/`.unit_release_logql`
  (`cli/sol/lib/sol_cli_logs.ml`) from `{namespace="%s",app="%s"}` to
  `{service=~".*%s.*"}`, dropping the now-unused `ns` parameter from each
  (call sites: `cli/sol/bin/cmd_logs.ml`, `cli/sol/lib/sol_cli_open.ml`'s
  `Service` scope case).
  `sol open logs`'s `Workspace`/`Domain` scopes (`{namespace=~"..."}`) were left
  untouched — those address the Alloy pod-stdout stream, which does carry a
  `namespace` label, and are out of this ticket's scope.
- `release_logql`/`unit_release_logql`'s `release="%s"` label is left as-is:
  grepping the framework and `obs-loki-eio` finds no code that ever emits a
  `release` label, so it's already a separate, pre-existing gap (FEAT-069/070
  territory), not part of this selector bug.
- Regression tests: `test_loki.ml`/`test_logs.ml` pin the new `{service=~".*<k8s_name>.*"}`
  selector shape; `examples/local-demo/test/test_e2e.ml`'s Loki-query e2e test
  now pushes a fixture stream labelled `service` (matching the real app-push
  vocabulary) instead of `namespace`/`app` — under the old code this fixture
  would no longer match, so it's now a real regression guard rather than a
  self-consistent no-op.
- No demo/example addition beyond the above: this is a bug fix to existing
  `sol logs` behavior, not a new app-author-facing primitive, CLI command, or
  generated manifest.
- Doc fix: `docs/architecture/devops-pipeline.md`'s `sol logs` section quoted
  the old `{namespace=...,app=...}` selector; updated to match.
