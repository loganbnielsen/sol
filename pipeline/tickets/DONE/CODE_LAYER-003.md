---
id: CODE_LAYER-003
type: code-layer-finding
severity: medium
source: project/audits/2026-09-05_code_layer_audit.md
---

Sun needs a single app-facing observability object

**Problem:** Scaffolded app entrypoints construct Loki/Prometheus/Tempo
backends, compose `Obs_eio` backends, parse `LOKI_URL`/`TEMPO_URL`, and pass
`?ot`/`?metrics_renderer` separately. App handlers also call lower-level
`Obs_eio.*` functions directly, so generated/user code has to know about span
handles, backend composition, metric registration, renderers, and primitive
push/scrape differences.

**Goal:** Add a Sun-owned `Sun_obs.t` facade that is the one observability
capability generated apps and app libraries use. Keep `obs-eio` as the neutral
event/backend core underneath; `Sun_obs` owns Sun env conventions, provider
bootstrap, primitive wiring, and ergonomic logging/metrics/tracing methods.

Put this behind an official Sun framework library, not a vague helper module:

```text
framework/sun-obs/lib
  -> library name: sun_obs
  -> depends on obs-eio, obs-loki-eio, obs-prometheus-eio, obs-tempo-eio
```

**Target shape:**

```text
generated app / app handler
  -> Sun_obs.t
  -> Obs_eio.t + primitive metrics settings
  -> Obs_eio neutral events
  -> Loki / Prometheus / Tempo adapters
```

**Design guidance:**

- Expose one app-facing object/capability, roughly:
  `obs.log.info`, `obs.log.warn`, `obs.metrics.counter`,
  `obs.metrics.gauge`, `obs.metrics.histogram`, `obs.trace.with_span`, and
  `obs.with_context`.
- Provider details stay out of generated app code: no direct
  `Obs_loki.create`, `Obs_prometheus.create`, `Obs_tempo.create`, or
  `Obs_eio.compose` in scaffolded `bin/main.ml`.
- Generated apps should depend on `sun_obs`, not directly on
  `obs-loki-eio`, `obs-prometheus-eio`, or `obs-tempo-eio` unless they are
  intentionally doing provider-specific work.
- Keep `Obs_eio.t` as the lower-level neutral core. Do not rewrite provider
  adapters just to make the Sun facade exist.
- It is fine if `Sun_obs.t` internally carries primitive-specific runtime
  pieces: services/workers scrape via a renderer; functions may push to
  Pushgateway. The public app capability should still feel the same.
- Framework APIs may keep lower-level internal parameters during the first
  pass if that keeps the diff small, but generated/user-facing code should
  move toward passing `Sun_obs.t`.
- Do not add a large metric registry DSL. Preserve the existing
  register-once/use-emitter model unless a simpler call-site API can be built
  without losing label validation or startup declarations.
- Do not create a generic `sun_helpers` package. The boundary is specifically
  observability:

```text
sun_env     -> runtime env capabilities
sun_obs     -> Sun observability facade/bootstrap
sun_svc     -> HTTP service primitive
sun_worker  -> Kafka worker primitive
sun_fn      -> scheduled/lambda function primitive
```

**Acceptance criteria:**

- `Sun_obs.t` is the primary observability value visible in generated app
  libraries and scaffolded entrypoints.
- A first-class `sun_obs` library exists under `framework/sun-obs/lib`.
- `Sun_obs` builds Loki/Prometheus/Tempo backends from Sun env conventions and
  applies service/team/domain context in one place.
- Scaffold templates stop manually composing provider backends.
- Scaffolded executable dune files depend on `sun_obs` instead of direct obs
  provider adapter packages where possible.
- App handler examples use the Sun-facing logging/tracing/metrics API instead
  of direct `Obs_eio.log_standalone`/`Obs_eio.with_context` calls.
- Service, worker, and function scaffolds all get observability through the
  same Sun facade, even if the framework bridge extracts different internal
  pieces for scrape vs. push behavior.
- `obs-eio` remains the neutral lower layer; changes there are limited to
  small ergonomic helpers only if the Sun facade would otherwise duplicate
  core behavior.
- Existing scaffold and framework tests pass.

## Resolution

Implemented and merged in this repo via PR #115 ("Add framework/sun-obs:
Sun_obs.t app-facing observability facade"), later extended by FEAT-030.
Ticket file was never moved to DONE after that merge — closing out the
bookkeeping gap now.
