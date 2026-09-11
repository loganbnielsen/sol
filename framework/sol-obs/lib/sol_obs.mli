(** Sol's app-facing observability facade.

    [Obs_eio] stays the neutral event/backend core; this module owns Sol's env
    conventions (which backends to wire up, from what env vars), provider
    bootstrap (Loki/Prometheus/Tempo composed together), and the ergonomic
    logging/metrics/tracing methods generated apps and app handlers call.
    Generated code should depend on [sol_obs], not directly on
    [obs-loki-eio]/[obs-prometheus-eio]/[obs-tempo-eio], unless it is
    intentionally doing provider-specific work.

    {[
      let obs = Sol_obs.of_env ~net:env#net ~clock:env#clock
                  ~mono_clock:env#mono_clock ~service:"payments-charge-svc"
                  ~context:[("team", "payments")] () in
      Sol_obs.log_info obs "starting up";
      Sol_obs.with_span obs "handle_charge" (fun sp ->
        Sol_obs.log sp Sol_obs.Info "charging customer";
        ...)
    ]} *)

type t

type level = Obs_eio.level =
  | Debug
  | Info
  | Warn
  | Error

type span = Obs_eio.span

(** Reads [LOKI_URL] and [TEMPO_URL] from the environment and composes whichever
    backends are configured: a Prometheus backend is always present; Loki is
    added when [LOKI_URL] is a non-empty env var, Tempo when [TEMPO_URL] is.
    Logs fall back to stdout when [LOKI_URL] is unset (Sol's local-dev default —
    see the top-level CLAUDE.md's "dev mirrors prod" principle: the same
    [of_env] call works unmodified against `sol dev up`'s real Loki/Tempo
    instances once those env vars are set by the platform). *)
val of_env
  :  net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> mono_clock:_ Eio.Time.Mono.t
  -> service:string
  -> ?context:(string * string) list
       (** Ambient context applied once via {!Obs_eio.with_context} — e.g.
        [team]/[domain] labels. Every key here is also promoted to a Loki stream
        label (see [obs-loki-eio]'s [label_names]), so keep this
        low-cardinality: team/domain/env, not per-request identifiers. Default:
        []. *)
  -> unit
  -> t

val log_debug : t -> ?fields:(string * string) list -> string -> unit
val log_info : t -> ?fields:(string * string) list -> string -> unit
val log_warn : t -> ?fields:(string * string) list -> string -> unit

(** Each opens and immediately closes its own span (like
    {!Obs_eio.log_standalone}) — use {!with_span} instead when several log calls
    or a duration belong to the same unit of work. *)
val log_error : t -> ?fields:(string * string) list -> string -> unit

(** Opens a span, runs the callback, closes the span on every exit path — see
    {!Obs_eio.with_span} for the full contract (this is that function, under
    Sol's facade). *)
val with_span : t -> ?parent:Obs_trace.t -> string -> (span -> 'a) -> 'a

(** Log within an open {!with_span} callback — see {!Obs_eio.log}. *)
val log : span -> level -> ?fields:(string * string) list -> string -> unit

(** The open span's trace context — pass this as {!with_span}'s [?parent] to
    link a child span (including one created by another process, e.g. a Kafka
    consumer's handler receiving it from a producer's message header), or as
    [Kafka_service.publish]'s [~trace_ctx] to propagate it over a W3C
    [traceparent] header. See {!Obs_eio.current_trace_context}. *)
val current_trace_context : span -> Obs_trace.t

(** The trace ID as a lowercase hex string (W3C [traceparent] format) — for
    logging, response headers, or a Grafana/Tempo lookup link, without the
    caller needing to know {!Obs_trace.t}'s internal representation. *)
val trace_id_string : Obs_trace.t -> string

val counter
  :  t
  -> name:string
  -> help:string
  -> label_names:string list
  -> Obs_eio.counter_fn

val gauge : t -> name:string -> help:string -> label_names:string list -> Obs_eio.gauge_fn

(** Register a metric family and get back an emitter — call once at startup,
    then call the returned function per event. Same register-once/use-emitter
    contract as {!Obs_eio.register_counter}/
    {!Obs_eio.register_gauge}/{!Obs_eio.register_histogram}, which these forward
    to directly. *)
val histogram
  :  t
  -> name:string
  -> help:string
  -> label_names:string list
  -> Obs_eio.histogram_fn

(** Derive a handle with additional ambient context — see
    {!Obs_eio.with_context}. Does not retroactively promote the new keys to Loki
    stream labels; pass everything you want promoted to {!of_env}'s [?context]
    up front. *)
val with_context : t -> (string * string) list -> t

(** {2 Framework primitive internals}

    [sol-svc], [sol-worker], and [sol-fn]'s own [run] functions all take a
    single [?ot:Sol_obs.t] directly now — these accessors are what each
    primitive uses internally to get back to the lower-level [Obs_eio.t]/
    renderer/backend it actually needs (registering metrics, serving [/metrics],
    pushing to Pushgateway). Application code has no reason to call these; use
    the functions above instead. *)

(** What [sol-svc]/[sol-worker] register per-request/per-message metrics against
    internally. *)
val obs_eio : t -> Obs_eio.t

(** What [sol-svc]/[sol-worker] render their built-in [/metrics] endpoint from
    internally — the Prometheus text-exposition renderer, regardless of which
    other backends are composed in. *)
val metrics_renderer : t -> unit -> string

(** What [sol-fn] builds its own job-scoped [Obs_eio.t] from internally — the
    full composed backend (every configured provider fanned out together, not
    Prometheus alone) paired with the same renderer as {!metrics_renderer},
    matching the shape [Obs_prometheus.create] returns. *)
val backend_and_renderer : t -> Obs_eio.backend * (unit -> string)
