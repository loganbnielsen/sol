# FND-0051 — Loki/Tempo export runs synchronously in the caller's fiber, and `LOKI_URL` replaces stdout: a slow Loki slows every log call, a down Loki loses the lines

- **Classification:** `DESIGN_GAP`
- **State:** `OPEN`
- **First identified:** 2026-09-24, correctness audit pass 2
- **Last verified:** 2026-09-24 (`origin/main @ fd5c7e0c`; obs-loki-eio, obs-tempo-eio as pinned)
- **Derived ticket:** `OBS-048`
- **Invariant:** the telemetry path must not couple application availability to a
  telemetry backend, and must not lose the evidence needed to diagnose that
  backend's outage.
- **Evidence class:** `BEHAVIORAL` (black-holed Loki)

## What is established

- `Obs_loki.create`'s `emit_span` (obs-loki-eio `obs_loki.ml:185-188`) POSTs each
  closed span, or standalone log line, to Loki inline, in the fiber that closed it,
  with a 5 s timeout. `Obs_tempo` does the same (`obs_tempo.ml:124-129`). With both
  configured, `Obs_eio.compose` runs them one after the other.
- A failed push raises `Failure`. `Obs_eio.with_span`'s `safe_call` catches it and
  prints `Obs_eio: backend_error op=emit_span ... exn=...` to stderr. The log line's
  own content is not printed.
- `Sol_obs.of_env` (`framework/ocaml/sol-obs/lib/sol_obs.ml:21-35`) makes Loki the
  *only* log backend when `LOKI_URL` is set; stdout is used only when it is not. So
  with `LOKI_URL` set, `kubectl logs` shows no application log lines.

Reproduced with `Sol_obs.of_env` against a TCP listener that accepts and never answers:

```
Obs_eio: backend_error op=emit_span name="log" exn="Failure(\"Loki push: request timed out after 5s\")"
log_info returned after 5.00s
```

The message (`order 42 accepted`) appears nowhere.

## Impact

Medium to high. While Loki is slow or unreachable, every log call and span in a
request handler or message handler blocks for up to 5 s (10 s with Tempo too), so
request latency and consumer throughput collapse together. The application's own log
lines are lost for the duration, including the ones that would explain the incident.
Rendered manifests set `LOKI_URL` (`default_cluster_env`), so this is the production
configuration.

## Remedy shape

In this repository: `Sol_obs` always also writes to stdout, so `kubectl logs` and the
node's log collection keep a copy. In the exporters (obs-loki-eio, obs-tempo-eio): a
bounded in-memory queue drained by a background fiber, batching pushes, dropping
oldest on overflow, and counting drops on a metric. Test: against a black-holed
endpoint, a log call returns promptly, and the line appears on stdout.
