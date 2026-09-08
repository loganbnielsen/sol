---
id: FEAT-031
type: feature
severity: medium
source: user request 2026-09-05/06 — "make the starter dashboard so people have a window into the functionality right away"
branch: FEAT-031/grafana-starter-dashboard
worktree: ../sun-FEAT-031-grafana-dashboard
pr: https://github.com/loganbnielsen/sun/pull/118
---

Add a provisioned starter Grafana dashboard for `examples/local-demo`, and wire the demo's Prometheus metrics through Pushgateway so they're actually visible (not just printed to stdout).

**Depends on:** None. (BUG-008's port-shadowing fix already unblocked local Loki/Tempo/Grafana access.)

## Problem

`ensure-grafana.sh` only ever provisioned Loki/Tempo datasources — no
Prometheus datasource, no dashboards at all. A person opening Grafana
after running the demo saw nothing without knowing to hand-type a LogQL
query, and had no path to metrics whatsoever: `examples/local-demo`'s
`Service.run`/`Worker.run` calls don't expose a live `/metrics` HTTP
endpoint (the processes are short-lived, one-shot runs, not long-running
scrape targets), and the demo's own `Obs_prometheus.push` call
(`PUSHGATEWAY_URL`) was never actually wired into anyone's run
instructions or Grafana setup.

Separately, `ensure-grafana.sh` pinned no Grafana version at all
(`grafana/grafana:latest`) — the only `ensure-*.sh` script that didn't —
which cost real debugging time this session chasing an auth regression in
whatever the newest Grafana release happened to be on a given day (see
BUG-008).

## Goal

Running the demo with `PUSHGATEWAY_URL` set and opening Grafana shows a
real, provisioned "Sun Demo Overview" dashboard immediately — request/
message counts, p50/p95 latency for both services, a Tempo pointer, and a
live logs panel — with zero manual query typing required.

## Remediation (done, verified live against real local infra)

- `ensure-prometheus.sh` and `ensure-grafana.sh`'s Loki datasource now
  provision with fixed UIDs (`prometheus`, `loki`, matching Tempo's
  existing `tempo` UID) instead of Grafana-assigned random ones, so a
  dashboard JSON can reference them reliably across container recreations.
- `ensure-grafana.sh` now mounts a dashboard-provisioning config
  (`platform/local/config/grafana-dashboards.yml`) and a dashboards
  directory (`platform/local/config/grafana-dashboards/`), pins
  `grafana/grafana:11.3.0` instead of `latest`.
- New `platform/local/config/grafana-dashboards/sun-demo-overview.json`:
  7 panels (request/message stat counters, a decode-errors stat, a Tempo
  pointer text panel, two duration timeseries panels, one logs panel).
  Duration panels use `histogram_quantile(q, sum(<bucket>) by (le))`
  directly — no `rate()` — because Pushgateway-sourced batch-job metrics
  are a one-time snapshot, not a continuously-scraped counter;
  `rate(...[5m])` on that shape returns `NaN` (verified, then fixed).
- Every panel query verified individually against Grafana's own
  datasource proxy (the exact path the UI uses) with live demo data,
  including the range-query form the timeseries panels actually render.

## Acceptance criteria

- A fresh `sun dev`/local-infra bring-up (`ensure-loki.sh`,
  `ensure-tempo.sh`, `ensure-pushgateway.sh`, `ensure-prometheus.sh`,
  `ensure-grafana.sh`, in that order or any order since each is idempotent
  and self-healing about network membership) plus one
  `PUSHGATEWAY_URL=http://localhost:9091 dune exec examples/local-demo/bin/demo.exe`
  run populates the "Sun Demo Overview" dashboard with real, non-empty,
  non-NaN values in every panel.
- `dune build`/`dune test` still pass.
- Demo run instructions (`bin/demo.ml`'s header comment, `docs/` if
  referenced there) mention `PUSHGATEWAY_URL` and the dashboard.
