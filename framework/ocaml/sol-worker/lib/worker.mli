(** Outcome for a retry-capable worker's [handle]. See {!RETRYABLE_WORKER}. *)
type outcome =
  | Ack
  | Retry of string
  | Dead_letter of string

(** Outcome for a basic worker's [handle]. The only case is [Ack]: a basic
    worker cannot express [Retry]/[Dead_letter] at all, so pairing it with a
    missing retry strategy is a type error, not a runtime surprise discovered
    the first time a handler wants to fail (FEAT-078). *)
type ack_outcome = Ack

(** A plain Kafka worker: consume, handle, ack. No retry capability — use
    {!RETRYABLE_WORKER} if [handle] needs to express [Retry]/[Dead_letter]. *)
module type WORKER = sig
  module Message : Kafka_service.MESSAGE

  (** Consumer group ID. Use a stable, service-scoped name, e.g.
      ["payments-broadcast-worker"]. *)
  val group_id : string

  (** Called once per successfully decoded message. [trace_ctx] carries the
      upstream [traceparent] header — pass it as [?parent:trace_ctx] to
      [Obs_eio.with_span] to link spans.

      The worker acknowledges (commits the offset) itself, only after [handle]
      returns [Ack] — there is no [ack] to call or forget, and no other
      outcome to return. A failed commit is logged and counted as
      [sol_worker_messages_total{status="ack_failed"}] rather than treated as
      a processing failure (see [run]'s note on ack failure semantics), since
      the side effect already happened and retrying it here could duplicate
      it. *)
  val handle : Message.t -> trace_ctx:Obs_trace.t option -> ack_outcome
end

(** A Kafka worker that can request retry or dead-letter handling for a
    failed message. Its [Make_with_retry(W).run] requires [~retry_strategy]
    — there is no implicit default (FEAT-078): a missing retry strategy must
    never be discovered only after a message first fails to process. *)
module type RETRYABLE_WORKER = sig
  module Message : Kafka_service.MESSAGE

  (** Consumer group ID. Use a stable, service-scoped name, e.g.
      ["payments-broadcast-worker"]. *)
  val group_id : string

  (** Called once per successfully decoded message. [trace_ctx] carries the
      upstream [traceparent] header — pass it as [?parent:trace_ctx] to
      [Obs_eio.with_span] to link spans.

      The worker acknowledges (commits the offset) itself, only after [handle]
      returns [Ack] — there is no [ack] to call or forget. A failed commit is
      logged and counted as [sol_worker_messages_total{status="ack_failed"}]
      rather than treated as a processing failure (see [run]'s note on ack
      failure semantics), since the side effect already happened and retrying
      it here could duplicate it.

      Return [Ack] to commit the offset, [Retry reason] to route through the
      configured retry strategy, or [Dead_letter reason] to route straight to
      the DLQ when [Retry_topics] is configured. Under [In_memory] (which has
      no DLQ), [Dead_letter] fails closed like an exhausted retry: the message
      is left unacknowledged rather than acknowledged-and-discarded (BUG-028's
      invariant). [reason] is diagnostic text only — never inspected by the
      runtime to decide delay, routing, or retryability; introduce an
      explicit typed concept if an application needs to influence policy. *)
  val handle : Message.t -> trace_ctx:Obs_trace.t option -> outcome
end

type retry_policy = Kafka.Consumer.retry_policy =
  { base_delay_s : float
    (** Initial backoff in seconds. Doubles on each consecutive failure. *)
  ; max_delay_s : float
    (** Backoff is capped at this value, even after jitter. Default: [600.0]
        (10 minutes). *)
  ; max_attempts : int
    (** Maximum handler invocations, including the initial one: with
          [max_attempts = 5] the handler runs 5 times total (initial + 4
          retries). Negative = retry indefinitely. [1] = no retry. Default:
          [-1]. *)
  ; jitter_ratio : float
    (** Symmetric jitter applied to the raw exponential delay before the
          [max_delay_s] clamp, as a fraction of that delay (e.g. [0.1] =
          ±10%). [0.0] disables jitter. Default: [0.1]. *)
  }

(** How the worker should handle transient failures from [W.handle]. Both
    variants share this one [retry_policy] vocabulary (FEAT-078) but are not
    feature-equivalent — exhaustion disposition is strategy-specific by
    design, not an oversight:

    - [In_memory retry] — exponential back-off sleep in the partition fiber
      (delay = [base_delay_s * 2^(attempt-1)], jittered, clamped to
      [max_delay_s]), pausing that Kafka partition for the retry delay.
      Backoff survives in-process but is lost on rebalance. On exhaustion, or
      on [Dead_letter] (which [In_memory] has no DLQ to route to): terminal
      handler failure — the message is left unacknowledged and the
      partition/worker fails under normal consumer semantics. No DLQ
      promise; this is the simple/dev option, not the production one.

    - [Retry_topics retry] — the raw message bytes are published to the
      group-scoped retry topic (BUG-030) and the original offset is
      committed immediately. A background retry consumer (group
      [<group_id>-sol-retry]) delays until the scheduled [X-Sol-Retry-At]
      timestamp, then re-runs [W.handle]. After [retry.max_attempts] total
      failures, or on [Dead_letter], the message is moved to the
      group-scoped DLQ topic, and the retry offset is acked only once that
      publish succeeds. Production Kafka-native option: durable retry + DLQ.

      Retry topics are at-least-once, not order-preserving: the delay blocks
      every later record sharing the retry partition, republishing gives the
      retry a later Kafka offset, and backlog or overload makes observed delay
      unbounded. *)
type retry_strategy = Kafka_service.retry_strategy =
  | In_memory of retry_policy
  | Retry_topics of retry_policy

type run_error =
  [ `Create of Kafka_service.error
  | `Register of Kafka_service.error
  | `Consume of Kafka_service.consume_partitioned_error
  ]

val run_error_to_string : run_error -> string

(** Plain Kafka worker: consume, handle, ack. No [retry_strategy] to pass —
    a basic [WORKER] cannot express failure at all, so there is nothing for
    one to select (FEAT-078). Use {!Make_with_retry} for a worker whose
    [handle] returns [Retry]/[Dead_letter]. *)
module Make (W : WORKER) : sig
  val run
    :  env:(_, _, _, _) Sol_env.timed
    -> config:Kafka_service.config
    -> ?ot:Sol_obs.t
         (** Observability handle. When provided, [sol_worker_messages_total{status}]
          (labels: [ok], [ack_failed] — a basic worker can never produce
          [retry]/[error]/[dead_letter]/[relay_published]/[relay_failed],
          since [handle] cannot return anything but [Ack]) and
          [sol_worker_message_duration_seconds] are emitted per message, and
          the worker exposes [GET /metrics] on [metrics_port] for Prometheus
          scraping.

          [ack_failed] means [W.handle] returned [Ack] but the subsequent
          offset commit failed, so the side effect already happened — logged
          at [Warn], and the message is left uncommitted for natural
          redelivery rather than retried immediately. Escalates to [Error]
          (stopping the worker) only when the commit failure is
          [Kafka.Error.is_fatal] — a broken consumer, not a transient
          hiccup — logged at [Error] in that case. *)
    -> ?metrics_port:int
         (** Port for the [/metrics] endpoint above. Default: [9090]. Only binds
          when [ot] is provided; pass [0] for an OS-assigned port (e.g. when
          running more than one [-worker]/[-svc] in the same process, or in
          tests) or when [ot] is provided purely for metric registration and
          another process already owns the default port. *)
    -> ?on_ready:(unit -> unit)
         (** Called exactly once when the broker assigns partitions to this
          consumer. *)
    -> ?stop:unit Eio.Promise.t
         (** External stop signal. Resolve to request graceful shutdown; checked
          alongside the worker's own SIGTERM/SIGINT handling, not in place of
          it. *)
    -> ?max_messages:int
         (** Stop cleanly after this many successfully processed messages. *)
    -> unit
    -> (unit, run_error) result
end

(** A retry-capable Kafka worker: consume, handle, ack — or route to the
    configured [retry_strategy] on [Retry]/[Dead_letter]. This is the
    breaking half of FEAT-078's split: a [WORKER] whose [handle] previously
    returned [Retry]/[Dead_letter] must become a {!RETRYABLE_WORKER} and use
    this functor instead of {!Make}. *)
module Make_with_retry (W : RETRYABLE_WORKER) : sig
  val run
    :  env:(_, _, _, _) Sol_env.timed
    -> config:Kafka_service.config
    -> retry_strategy:retry_strategy
         (** Failure strategy for [Retry]/[Dead_letter] results from
          [W.handle]. Mandatory, not optional (FEAT-078): there is no implicit
          fallback. See [retry_strategy] for the two modes. *)
    -> ?ot:Sol_obs.t
         (** Observability handle. When provided,
          [sol_worker_messages_total{status}] (labels: [ok], [retry], [error],
          [dead_letter], [ack_failed], [relay_published], [relay_failed] --
          the last two [Retry_topics]-only, BUG-029) and
          [sol_worker_message_duration_seconds] are emitted
          per message, and the worker exposes [GET /metrics] on [metrics_port]
          for Prometheus scraping.

          [ack_failed] is distinct from [error]: it means [W.handle] returned
          [Ack] but the subsequent offset commit failed, so the side effect
          already happened — logged at [Warn], and the message is left
          uncommitted for natural redelivery rather than retried immediately.
          Escalates to [Error] (stopping the worker) only when the commit
          failure is [Kafka.Error.is_fatal] — a broken consumer, not a transient
          hiccup — logged at [Error] in that case. *)
    -> ?metrics_port:int
         (** Port for the [/metrics] endpoint above. Default: [9090]. Only binds
          when [ot] is provided; pass [0] for an OS-assigned port (e.g. when
          running more than one [-worker]/[-svc] in the same process, or in
          tests) or when [ot] is provided purely for metric registration and
          another process already owns the default port. *)
    -> ?on_ready:(unit -> unit)
         (** Called exactly once when the broker assigns partitions to this
          consumer. *)
    -> ?stop:unit Eio.Promise.t
         (** External stop signal. Resolve to request graceful shutdown; checked
          alongside the worker's own SIGTERM/SIGINT handling, not in place of
          it. *)
    -> ?max_messages:int
         (** Stop cleanly after this many successfully processed messages. *)
    -> unit
    -> (unit, run_error) result
end

(** Test-only hooks for unit tests that drive the worker handler without
    Kafka. *)
module For_testing : sig
  module Make (W : WORKER) : sig
    val run
      :  env:(_, _, _, _) Sol_env.timed
      -> config:Kafka_service.config
      -> ?ot:Sol_obs.t
      -> ?metrics_port:int
      -> ?on_ready:(unit -> unit)
      -> ?stop:unit Eio.Promise.t
      -> ?max_messages:int
      -> ?test_consume_loop:
           (handler:
              (W.Message.t
               -> ack:(unit -> (unit, Kafka.Error.t) result)
               -> trace_ctx:Obs_trace.t option
               -> Kafka.Error.t Kafka.Consumer.handler_result)
            -> unit
            -> unit)
      -> unit
      -> (unit, run_error) result
  end

  module Make_with_retry (W : RETRYABLE_WORKER) : sig
    val run
      :  env:(_, _, _, _) Sol_env.timed
      -> config:Kafka_service.config
      -> retry_strategy:retry_strategy
      -> ?ot:Sol_obs.t
      -> ?metrics_port:int
      -> ?on_ready:(unit -> unit)
      -> ?stop:unit Eio.Promise.t
      -> ?max_messages:int
      -> ?test_consume_loop:
           (handler:
              (W.Message.t
               -> ack:(unit -> (unit, Kafka.Error.t) result)
               -> trace_ctx:Obs_trace.t option
               -> Kafka_service.handler_error Kafka.Consumer.handler_result)
            -> unit
            -> unit)
      -> unit
      -> (unit, run_error) result
  end
end
