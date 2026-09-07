module type WORKER = sig
  module Message : Kafka_service.MESSAGE

  val group_id : string
  (** Consumer group ID. Use a stable, service-scoped name, e.g. ["payments-broadcast-worker"]. *)

  val handle : Message.t -> trace_ctx:Obs_trace.t option -> (unit, string) result
  (** Called once per successfully decoded message. [trace_ctx] carries the upstream
      [traceparent] header — pass it as [?parent:trace_ctx] to [Obs_eio.with_span] to
      link spans.

      The worker acknowledges (commits the offset) itself, only after [handle]
      returns [Ok ()] — there is no [ack] to call or forget. A failed commit is
      logged and counted as [sol_worker_messages_total{status="ack_failed"}]
      rather than treated as a processing failure (see [run]'s note on ack
      failure semantics), since the side effect already happened and retrying
      it here could duplicate it.

      Return [Error msg] to signal a retryable failure (nothing is acknowledged).
      The worker retries the same message using the [retry] policy passed to
      [Make(W).run]. Once [max_attempts] is exhausted (if non-negative), the
      worker stops and [Make(W).run] returns [Error]. *)
end

type retry_policy = Kafka.Consumer.retry_policy = {
  base_delay_s : float;
  (** Initial backoff in seconds. Doubles on each consecutive failure. *)
  max_delay_s  : float;
  (** Backoff is capped at this value. Default: [600.0] (10 minutes). *)
  max_attempts : int;
  (** Maximum number of attempts before the worker stops. Negative = retry
      indefinitely. Default: [-1]. *)
}

(** How the worker should handle transient failures from [W.handle].

    - [In_memory retry] (default) — exponential back-off sleep in the
      partition fiber.  Backoff survives in-process but is lost on rebalance.

    - [Retry_topics { max_attempts }] — the raw message bytes are published
      to [<topic>-retry] and the original offset is committed immediately.
      A background retry consumer (group [<group_id>-sol-retry]) delays until
      the scheduled [X-Sol-Retry-At] timestamp, then re-runs [W.handle].
      After [max_attempts] total failures the message is moved to [<topic>-dlq].
      Both topics are auto-provisioned on startup. *)
type retry_strategy = Kafka_service.retry_strategy =
  | In_memory    of retry_policy
  | Retry_topics of { max_attempts : int }

type run_error =
  [ `Create   of Kafka_service.error
  | `Register of Kafka_service.error
  | `Consume  of Kafka_service.consume_partitioned_error
  ]

val run_error_to_string : run_error -> string

module Make (W : WORKER) : sig
  val run
    :  env:(_, _, _, _) Sol_env.timed
    -> config:Kafka_service.config
    -> ?ot:Sol_obs.t
    (** Observability handle. When provided, [sol_worker_messages_total{status}]
        (labels: [ok], [retry], [error], [ack_failed]) and
        [sol_worker_message_duration_seconds] are emitted per message, and
        the worker exposes [GET /metrics] on [metrics_port] for Prometheus
        scraping.

        [ack_failed] is distinct from [error]: it means [W.handle] returned
        [Ok ()] but the subsequent offset commit failed, so the side effect
        already happened — logged at [Warn], and the message is left
        uncommitted for natural redelivery rather than retried immediately.
        Escalates to [Error] (stopping the worker) only when the commit
        failure is [Kafka.Error.is_fatal] — a broken consumer, not a
        transient hiccup — logged at [Error] in that case. *)
    -> ?metrics_port:int
    (** Port for the [/metrics] endpoint above. Default: [9090]. Only binds
        when [ot] is provided; pass [0] for an OS-assigned port (e.g. when
        running more than one [-worker]/[-svc] in the same process, or in
        tests) or when [ot] is provided purely for metric registration and
        another process already owns the default port. *)
    -> ?on_ready:(unit -> unit)
    (** Called exactly once when the broker assigns partitions to this consumer. *)
    -> ?stop:unit Eio.Promise.t
    (** External stop signal. Resolve to request graceful shutdown; checked
        alongside the worker's own SIGTERM/SIGINT handling, not in place of it. *)
    -> ?max_messages:int
    (** Stop cleanly after this many successfully processed messages. *)
    -> ?retry_strategy:retry_strategy
    (** Failure strategy for [Error] results from [W.handle]. Defaults to
        [In_memory default_retry]. See [retry_strategy] for the two modes. *)
    -> unit
    -> (unit, run_error) result
end

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
      -> ?retry_strategy:retry_strategy
      -> ?test_consume_loop:
           (handler:(W.Message.t -> ack:(unit -> (unit, Kafka.Error.t) result) -> trace_ctx:Obs_trace.t option -> Kafka.Error.t Kafka.Consumer.handler_result)
            -> unit -> unit)
      -> unit
      -> (unit, run_error) result
  end
end
(** Test-only hook for unit tests that drive the worker handler without Kafka. *)
