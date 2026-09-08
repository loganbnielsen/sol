---
id: FEAT-030
type: feature
severity: medium
source: user request 2026-09-05 — "redo demoing" after CODE_LAYER-003
branch: FEAT-030/demo-sun-obs-dogfood
worktree: ../sun-FEAT-030-demo-sun-obs
pr: https://github.com/loganbnielsen/sun/pull/116
---

Redo `examples/local-demo` to dogfood `Sun_obs` and showcase the full observability story (logs, metrics, traces, storage) at the abstraction level a real Sun app gets.

**Depends on:** None. (CODE_LAYER-003/`framework/sun-obs` already merged — this is the consumer-side follow-up.)

## Problem

`examples/local-demo` predates `framework/sun-obs` (CODE_LAYER-003) and still
hand-composes `Obs_eio`/`Obs_loki`/`Obs_prometheus`/`Obs_tempo` directly in
`bin/demo.ml`, the exact pattern the new facade exists to replace in
generated scaffolds. The demo is meant to show "how well abstracted the core
design components are" — right now it shows the opposite: ~15 lines of
manual backend composition per service instead of one `Sun_obs.of_env` call.

Separately, the demo previously only wired Tempo into `order-svc`
("`-svc` only", a historical `OBS-042` non-goal). Now that `Sun_obs` gives
every primitive the same wiring for free, `fulfillment-worker` should also
get real tracing (a `fulfill_order` span, child of the HTTP request's
`receive_order` span) — this is a concrete, demoable capability upgrade
from CODE_LAYER-003, not just a refactor.

## Goal

- `bin/demo.ml` builds `svc_obs`/`worker_obs` via `Sun_obs.of_env`, using
  `Sun_obs.with_span`/`log`/`with_context`/`obs_eio`/`metrics_renderer`
  instead of direct `Obs_eio`/`Obs_loki`/`Obs_prometheus`/`Obs_tempo` calls,
  matching what a real scaffolded `-svc`/`-worker` app does.
- `fulfillment-worker` gets a real `fulfill_order` Tempo span, linked as a
  child of `order-svc`'s `receive_order` span for the same order.
- The demo still prints its own Prometheus snapshot and runs its own
  assertions (each service keeps its own independent registry, matching
  two real separately-scraped processes — the demo stitches both renders
  together for the snapshot/assertions, it does not share one registry).
- `bin/dune` depends on `sun_obs` instead of the raw provider packages
  (keeping `obs-eio`/`obs-prometheus-eio` only for the handful of calls
  `Sun_obs`'s `.mli` deliberately doesn't wrap — `Obs_eio.current_trace_context`
  for Kafka header propagation, `Obs_prometheus.push` for the optional
  Pushgateway path).
- Demo runs cleanly end-to-end against real local infra (`ensure-broker.sh`,
  `ensure-postgres.sh`, `ensure-loki.sh`, `ensure-tempo.sh`,
  `ensure-prometheus.sh`, `ensure-grafana.sh`), including its own
  assertions, modulo pre-existing infra bugs already ticketed separately
  (`BUG-008` Loki, `BUG-009` Tempo-under-concurrency) — do not silently
  paper over either by disabling the assertions; report their current
  status honestly (e.g. `skip`/known-flaky note referencing the ticket)
  rather than deleting the check.

## Review process (this ticket specifically)

In addition to the normal `/review-worktree` gate, this ticket asks for a
persona-based review pass before submission, evaluating: (a) does the demo
actually work end-to-end and clearly show off logs/metrics/traces/storage;
(b) is the amount of code an app author has to write to get this
appropriately small, or does something that reads as boilerplate belong as
a library-provided helper instead. Use (or create, if none exists yet) a
skill for this persona-review loop — see if `demo-review` or similar
already exists before building one from scratch.

## Acceptance criteria

- `dune build` and `dune test` pass.
- A live `dune exec examples/local-demo/bin/demo.exe` run (with all
  optional backends available) passes its own assertions, or documents
  exactly which ones are blocked by `BUG-008`/`BUG-009` and why.
- No direct `Obs_loki`/`Obs_prometheus`/`Obs_tempo` composition remains in
  `bin/demo.ml` — only `Sun_obs` plus the deliberate low-level bridges
  noted above.
- The persona review (demo agent + client agent, or equivalent) approves,
  and a fresh reviewer's final pass approves.
