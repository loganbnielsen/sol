(** [Retry_topics] strategy backing [Kafka_service.consume_partitioned] —
    see that function's [.mli] doc for the retry/DLQ topic contract. Only
    [consume] is called from [Kafka_service]; the rest is exposed for
    direct unit testing of the retry-routing decision and header codec. *)

(** Typed outcome for a single retry-routing decision. *)
type retry_action =
  | Ack
  | Forward_retry of { target : Kafka_service_intf.topic_name; delay_s : float }
  | Forward_dlq   of { target : Kafka_service_intf.topic_name }

val parse_retry_metadata
  :  (string * string option) list
  -> (int * float, string) result
(** Read and validate the [X-Sol-Attempt]/[X-Sol-Retry-At] headers off a
    message forwarded to a retry topic. *)

val execute_action
  :  retry_action
  -> raw_msg:Kafka.Consumer.message
  -> attempt:int
  -> publish_raw:(target_topic:Kafka_service_intf.topic_name -> attempt:int -> raw_bytes:bytes option -> headers:(string * string option) list -> delay_s:float -> partition:int32 -> (unit, Kafka.Error.t) result)
  -> ack:(unit -> (unit, Kafka.Error.t) result)
  -> (unit, Kafka.Error.t) result
(** Execute the side-effecting part of a retry decision: publish to the
    target topic (for [Forward_retry]/[Forward_dlq]) then [ack]. [Ack]
    skips straight to acking. *)

val consume
  :  Kafka_service_intf.t
  -> 'a Kafka_service_intf.topic
  -> group_id:string
  -> sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> max_attempts:int
  -> on_ready:(unit -> unit)
  -> on_decode_error:(string -> raw_bytes:bytes option -> ack:(unit -> (unit, Kafka.Error.t) result) -> Kafka.Error.t Kafka.Consumer.handler_result)
  -> on_retry:(partition:int32 -> attempt:int -> delay_s:float -> unit)
  -> handler:('a -> ack:(unit -> (unit, Kafka.Error.t) result) -> trace_ctx:Obs_trace.t option -> Kafka.Error.t Kafka.Consumer.handler_result)
  -> unit
  -> (unit, Kafka_service_intf.consume_partitioned_error) result
