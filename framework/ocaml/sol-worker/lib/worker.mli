type outcome =
  | Ack
  | Retry of string
  | Dead_letter of string

type ack_outcome = Ack

module type WORKER = sig
  module Message : Kafka_service.MESSAGE

  val group_id : string
  val handle : Message.t -> trace_ctx:Obs_trace.t option -> ack_outcome
end

module type RETRYABLE_WORKER = sig
  module Message : Kafka_service.MESSAGE

  val group_id : string
  val handle : Message.t -> trace_ctx:Obs_trace.t option -> outcome
end

type retry_policy = Kafka.Consumer.retry_policy =
  { base_delay_s : float
  ; max_delay_s : float
  ; max_attempts : int
  ; jitter_ratio : float
  }

type retry_strategy = Kafka_service.retry_strategy =
  | In_memory of retry_policy
  | Retry_topics of retry_policy

type decode_error_policy = Kafka_service.decode_error_policy =
  | Route_to_dlq
  | Ack_and_drop

type run_error =
  [ `Create of Kafka_service.error
  | `Register of Kafka_service.error
  | `Consume of Kafka_service.consume_partitioned_error
  ]

val run_error_to_string : run_error -> string

module Make (W : WORKER) : sig
  val run
    :  env:(_, _, _, _) Sol_env.timed
    -> config:Kafka_service.config
    -> ?ot:Sol_obs.t
    -> ?metrics_port:int
    -> ?on_ready:(unit -> unit)
    -> ?stop:unit Eio.Promise.t
    -> ?max_messages:int
    -> unit
    -> (unit, run_error) result
end

module Make_with_retry (W : RETRYABLE_WORKER) : sig
  val run
    :  env:(_, _, _, _) Sol_env.timed
    -> config:Kafka_service.config
    -> retry_strategy:retry_strategy
    -> ?decode_error_policy:decode_error_policy
    -> ?ot:Sol_obs.t
    -> ?metrics_port:int
    -> ?on_ready:(unit -> unit)
    -> ?stop:unit Eio.Promise.t
    -> ?max_messages:int
    -> unit
    -> (unit, run_error) result
end

module For_testing : sig
  val join_stop
    :  sw:Eio.Switch.t
    -> ?signal:unit Eio.Promise.t
    -> ?caller:unit Eio.Promise.t
    -> unit
    -> unit Eio.Promise.t

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
      -> ?decode_error_policy:decode_error_policy
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
