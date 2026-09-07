# sol-obs — Observability Facade

## Overview

`obs-eio` is the neutral event/backend core: spans, metrics, trace context,
and a `backend` interface any provider adapter implements. Before this
package existed, every scaffolded app entrypoint had to compose Loki/
Prometheus/Tempo backends itself, parse `LOKI_URL`/`TEMPO_URL`, and pass
`?ot`/`?metrics_renderer` around by hand — app handler code called
`Obs_eio.*` directly, so generated/user code had to know about span
handles, backend composition, and primitive push/scrape differences.

`sol_obs` is the one observability capability generated apps and app
libraries use. It owns Sol's env conventions and provider bootstrap;
`obs-eio` stays the lower-level core underneath, unchanged.

```text
generated app / app handler
  -> Sol_obs.t
  -> Obs_eio.t + Prometheus renderer
  -> Obs_eio neutral events
  -> Loki / Prometheus / Tempo adapters
```

## Package Structure

```
framework/sol-obs/
  lib/
    sol_obs.ml
    sol_obs.mli
    dune
  test/
    test_sol_obs.ml
    dune
```

Library name: `sol_obs`. Depends on `obs-eio`, `obs-loki-eio`,
`obs-prometheus-eio`, `obs-tempo-eio`.

## Public API

```ocaml
type t
type level = Obs_eio.level = Debug | Info | Warn | Error
type span = Obs_eio.span

val of_env
  :  net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> mono_clock:_ Eio.Time.Mono.t
  -> service:string -> ?context:(string * string) list -> unit -> t

val log_debug : t -> ?fields:(string * string) list -> string -> unit
val log_info  : t -> ?fields:(string * string) list -> string -> unit
val log_warn  : t -> ?fields:(string * string) list -> string -> unit
val log_error : t -> ?fields:(string * string) list -> string -> unit

val with_span : t -> ?parent:Obs_trace.t -> string -> (span -> 'a) -> 'a
val log : span -> level -> ?fields:(string * string) list -> string -> unit

val counter   : t -> name:string -> help:string -> label_names:string list -> Obs_eio.counter_fn
val gauge     : t -> name:string -> help:string -> label_names:string list -> Obs_eio.gauge_fn
val histogram : t -> name:string -> help:string -> label_names:string list -> Obs_eio.histogram_fn

val with_context : t -> (string * string) list -> t

(* Framework primitive bridges — for sol-svc/sol-worker/sol-fn's own [run]
   functions, not application code. *)
val obs_eio : t -> Obs_eio.t
val metrics_renderer : t -> unit -> string
val backend_and_renderer : t -> Obs_eio.backend * (unit -> string)
```

`of_env` reads `LOKI_URL`/`TEMPO_URL` and composes whichever backends are
configured; Prometheus is always present. `?context` is applied once via
`Obs_eio.with_context` and every key in it is also promoted to a Loki
stream label — keep it low-cardinality (team/domain/env), not per-request
data.

## Configuration

| Env var | Effect when set | Effect when unset |
|---|---|---|
| `LOKI_URL` | Logs push to Loki | Logs go to stdout |
| `TEMPO_URL` | Spans push to Tempo | No trace backend |

Prometheus is unconditional: `metrics_renderer`/`backend_and_renderer`
always return a working renderer, whether or not anything else is
configured.

## Design Decisions

- **Register-once/use-emitter preserved.** `counter`/`gauge`/`histogram`
  forward straight to `Obs_eio.register_*` — no metric registry DSL. Call
  once at startup, keep the returned emitter, call it per event.
- **Three framework internal accessors, not one.** `sol-svc`, `sol-worker`,
  and `sol-fn` all take `?ot:Sol_obs.t` directly now, and each unpacks it
  back down to the raw shape it actually needs internally: `obs_eio` for
  `-svc`/`-worker`'s per-request/per-message metric registration,
  `metrics_renderer` for their built-in `/metrics` endpoint,
  `backend_and_renderer` for `-fn`'s own job-scoped `Obs_eio.t`
  construction per invocation (its two return values happen to match
  `Obs_prometheus.create`'s shape exactly). Application/scaffold code
  never touches these — see CODE_LAYER-012.
- **Context vs. stream labels.** `with_context` (post-`of_env`) does not
  retroactively promote new keys to Loki stream labels — only `of_env`'s
  `?context` does, since Loki's `label_names` set is fixed at backend
  creation. Anything meant to be a stream label must be known at `of_env`
  time.

## Example Usage

```ocaml
let obs =
  Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
    ~service:"payments-charge-svc" ~context:[("team", "payments")] ()
in
Sol_obs.log_info obs "starting up";
Service.run (Handler.routes pool ~obs) ~env ~ot:obs ()
```

Inside a handler:

```ocaml
Sol_obs.with_span obs "handle_charge" (fun sp ->
  Sol_obs.log sp Sol_obs.Info "charging customer" ~fields:[("customer_id", id)];
  ...)
```

## Out of Scope (v1)

- A metric registry/declaration DSL beyond `obs-eio`'s existing
  register-once model.
- Retroactively promoting `with_context` keys to Loki stream labels after
  `of_env`.
