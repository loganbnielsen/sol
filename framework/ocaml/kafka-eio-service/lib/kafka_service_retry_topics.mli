type retry_action =
  | Ack
  | Forward_retry of
      { target : Kafka_service_intf.topic_name
      ; delay_s : float
      }
  | Forward_dlq of { target : Kafka_service_intf.topic_name }

val parse_retry_metadata : (string * string option) list -> (int * float, string) result
val produce_backoff_s : int -> float

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
  -> retry_policy:Kafka.Consumer.retry_policy
  -> attempt:int
  -> Kafka_service_intf.handler_error
  -> (retry_action, Kafka.Error.t) result

type relay =
  { source : Kafka.Consumer.message
  ; headers : (string * string option) list
  ; attempt : int
  ; delay_s : float
  }

val retry_message
  :  raw_msg:Kafka.Consumer.message
  -> attempt:int
  -> delay_s:float
  -> relay

val dead_letter_message
  :  raw_msg:Kafka.Consumer.message
  -> attempt:int
  -> group_id:string
  -> relay

val decode_failure_message
  :  raw_msg:Kafka.Consumer.message
  -> attempt:int
  -> decode_error:string
  -> group_id:string
  -> relay

val execute_action
  :  group_id:string
  -> retry_action
  -> raw_msg:Kafka.Consumer.message
  -> attempt:int
  -> publish:
       (target_topic:Kafka_service_intf.topic_name
        -> relay
        -> (unit, Kafka.Error.t) result)
  -> ack:(unit -> (unit, Kafka.Error.t) result)
  -> (unit, Kafka.Error.t) result

val route_decode_error
  :  stage:[ `Source | `Retry ]
  -> dlq_topic:Kafka_service_intf.topic_name
  -> raw_msg:Kafka.Consumer.message
  -> attempt:int
  -> decode_error:string
  -> group_id:string
  -> publish:
       (target_topic:Kafka_service_intf.topic_name
        -> relay
        -> (unit, Kafka.Error.t) result)
  -> ack:(unit -> (unit, Kafka.Error.t) result)
  -> (unit, Kafka.Error.t) result

val relay_topic_name : source:string -> group_id:string -> suffix:string -> string

type record_stage =
  | Source
  | Retry of int

val process_handler_result
  :  stage:record_stage
  -> retry_topic:Kafka_service_intf.topic_name
  -> dlq_topic:Kafka_service_intf.topic_name
  -> retry_policy:Kafka.Consumer.retry_policy
  -> group_id:string
  -> raw_msg:Kafka.Consumer.message
  -> publish:
       (target_topic:Kafka_service_intf.topic_name
        -> relay
        -> (unit, Kafka.Error.t) result)
  -> ack:(unit -> (unit, Kafka.Error.t) result)
  -> Kafka_service_intf.handler_error Kafka.Consumer.handler_result
  -> Kafka.Error.t Kafka.Consumer.handler_result

type 'a runtime =
  { group_id : string
  ; retry_policy : Kafka.Consumer.retry_policy
  ; hooks : Kafka_service_intf.consumer_hooks
  ; decode_error_policy : Kafka_service_intf.decode_error_policy
  ; observe_decode_error :
      string
      -> raw_bytes:bytes option
      -> disposition:[ `Dropped | `Dead_lettered ]
      -> unit
  ; handler :
      'a
      -> ack:(unit -> (unit, Kafka.Error.t) result)
      -> trace_ctx:Obs_trace.t option
      -> Kafka_service_intf.handler_error Kafka.Consumer.handler_result
  }

val consume
  :  Kafka_service_intf.t
  -> 'a Kafka_service_intf.topic
  -> sw:Eio.Switch.t
  -> net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> 'a runtime
  -> unit
  -> (unit, Kafka_service_intf.consume_partitioned_error) result
