(** [Retry_topics] strategy backing [Kafka_service.consume_partitioned] — see
    that function's [.mli] doc for the retry/DLQ topic contract. Only [consume]
    is called from [Kafka_service]; the rest is exposed for direct unit testing
    of the retry-routing decision and header codec. *)

(** Typed outcome for a single retry-routing decision. *)
type retry_action =
  | Ack
  | Forward_retry of
      { target : Kafka_service_intf.topic_name
      ; delay_s : float
      }
  | Forward_dlq of { target : Kafka_service_intf.topic_name }

(** Read and validate the [X-Sol-Attempt]/[X-Sol-Retry-At] headers off a message
    forwarded to a retry topic. *)
val parse_retry_metadata : (string * string option) list -> (int * float, string) result

(** BUG-029: backoff (with jitter, capped) for the relay's in-process produce
    retry, keyed by produce attempt number (1-based). Not the user-facing
    retry_policy vocabulary FEAT-078 will introduce -- this only bounds the
    relay's own producer resilience. Exposed for testing the shape of the
    schedule (monotonic growth, cap, non-negativity), not its exact jittered
    value. *)
val produce_backoff_s : int -> float

(** [retry_produce ~max_attempts ~backoff_s ~sleep ~on_retry ~produce ()] retries
    [produce] up to [max_attempts] times, calling [on_retry ~attempt ~error] and
    [sleep (backoff_s attempt)] between attempts. Exposed so the retry-count and
    give-up behavior can be tested with stubbed [produce]/[sleep], without a
    live broker or a real clock (BUG-029). *)
val retry_produce
  :  max_attempts:int
  -> backoff_s:(int -> float)
  -> sleep:(float -> unit)
  -> on_retry:(attempt:int -> error:'e -> unit)
  -> produce:(unit -> (unit, 'e) result)
  -> unit
  -> (unit, 'e) result

val action_of_handler_error
  :  retry_topic:Kafka_service_intf.topic_name
  -> dlq_topic:Kafka_service_intf.topic_name
  -> max_attempts:int
  -> attempt:int
  -> Kafka_service_intf.handler_error
  -> (retry_action, Kafka.Error.t) result

(** Execute the side-effecting part of a retry decision: publish to the target
    topic (for [Forward_retry]/[Forward_dlq]) then [ack]. [Ack] skips straight
    to acking. The message's key travels with it (BUG-027), so a retried
    message hashes to the same partition on the target topic that its key
    would hash to on the source topic. *)
val execute_action
  :  ?headers:(string * string option) list
  -> retry_action
  -> raw_msg:Kafka.Consumer.message
  -> attempt:int
  -> publish_raw:
       (target_topic:Kafka_service_intf.topic_name
        -> attempt:int
        -> raw_bytes:bytes option
        -> key:bytes option
        -> headers:(string * string option) list
        -> delay_s:float
        -> partition:int32
        -> (unit, Kafka.Error.t) result)
  -> ack:(unit -> (unit, Kafka.Error.t) result)
  -> (unit, Kafka.Error.t) result

(** On a retry-topic decode failure, publish the raw retry record (with decode
    diagnostics attached) to the DLQ rather than reaching the source-path
    [on_decode_error] skip-and-ack contract (BUG-028: that contract would
    ack-drop the last durable copy of the message). *)
val route_retry_decode_error
  :  dlq_topic:Kafka_service_intf.topic_name
  -> raw_msg:Kafka.Consumer.message
  -> attempt:int
  -> decode_error:string
  -> publish_raw:
       (target_topic:Kafka_service_intf.topic_name
        -> attempt:int
        -> raw_bytes:bytes option
        -> key:bytes option
        -> headers:(string * string option) list
        -> delay_s:float
        -> partition:int32
        -> (unit, Kafka.Error.t) result)
  -> ack:(unit -> (unit, Kafka.Error.t) result)
  -> (unit, Kafka.Error.t) result

(** [on_relay_publish] fires after each attempt to publish to the retry/DLQ
    topic itself resolves -- [`Published] once (after in-process produce
    retries succeed), [`Failed] once if they're exhausted (BUG-029). Distinct
    from [on_retry], which fires once per record when a retry is *scheduled*,
    before publication is attempted. *)
val consume
  :  Kafka_service_intf.t
  -> 'a Kafka_service_intf.topic
  -> group_id:string
  -> sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> max_attempts:int
  -> on_ready:(unit -> unit)
  -> on_decode_error:
       (string
        -> raw_bytes:bytes option
        -> ack:(unit -> (unit, Kafka.Error.t) result)
        -> Kafka.Error.t Kafka.Consumer.handler_result)
  -> on_retry:(partition:int32 -> attempt:int -> delay_s:float -> unit)
  -> on_relay_publish:
       (partition:int32 -> attempt:int -> outcome:[ `Published | `Failed ] -> unit)
  -> handler:
       ('a
        -> ack:(unit -> (unit, Kafka.Error.t) result)
        -> trace_ctx:Obs_trace.t option
        -> Kafka_service_intf.handler_error Kafka.Consumer.handler_result)
  -> unit
  -> (unit, Kafka_service_intf.consume_partitioned_error) result
