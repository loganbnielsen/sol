type topic_name

type error =
  | Invalid_topic_name of string * string
  | Config of string
  | Create of Kafka.Error.t
  | Topic_metadata of topic_name * string
  | Partition_count_reduction of
      { topic_name : topic_name
      ; current : int
      ; requested : int
      }
  | Insufficient_replication of
      { topic_name : topic_name
      ; current : int
      ; required : int
      }
  | Provision_topic of topic_name * Kafka.Error.t
  | Schema_registry of topic_name * string

val topic_name_to_string : topic_name -> string
val error_to_string : error -> string
val topic_name : string -> (topic_name, error) result
val topic_name_exn : string -> topic_name

module type MESSAGE = sig
  type t

  val topic_name : topic_name
  val schema : string
  val encode : t -> Yojson.Safe.t
  val decode : Yojson.Safe.t -> (t, string) result
end

type handler_error =
  | Retry
  | Dead_letter of string
  | Kafka_error of Kafka.Error.t

type decode_error_policy =
  | Route_to_dlq
  | Ack_and_drop

module Schema : sig
  val check
    :  net:_ Eio.Net.t
    -> clock:_ Eio.Time.clock
    -> registry_url:string
    -> (module MESSAGE)
    -> (unit, error) result

  val check_all
    :  net:_ Eio.Net.t
    -> clock:_ Eio.Time.clock
    -> registry_url:string
    -> (module MESSAGE) list
    -> (unit, error) result

  type compatibility_response = { is_compatible : bool }
  type registration_response = { id : int }

  val is_subject_not_found : string -> bool
  val decode_compatibility_response : string -> (compatibility_response, string) result
  val decode_registration_response : string -> (registration_response, string) result
end

module Retry_topics : sig
  type retry_action =
    | Ack
    | Forward_retry of
        { target : topic_name
        ; delay_s : float
        }
    | Forward_dlq of { target : topic_name }

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
    :  retry_topic:topic_name
    -> dlq_topic:topic_name
    -> retry_policy:Kafka.Consumer.retry_policy
    -> attempt:int
    -> handler_error
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
    -> publish:(target_topic:topic_name -> relay -> (unit, Kafka.Error.t) result)
    -> ack:(unit -> (unit, Kafka.Error.t) result)
    -> (unit, Kafka.Error.t) result

  val route_decode_error
    :  stage:[ `Source | `Retry ]
    -> dlq_topic:topic_name
    -> raw_msg:Kafka.Consumer.message
    -> attempt:int
    -> decode_error:string
    -> group_id:string
    -> publish:(target_topic:topic_name -> relay -> (unit, Kafka.Error.t) result)
    -> ack:(unit -> (unit, Kafka.Error.t) result)
    -> (unit, Kafka.Error.t) result

  val relay_topic_name : source:string -> group_id:string -> suffix:string -> string

  type record_stage =
    | Source
    | Retry of int

  val process_handler_result
    :  stage:record_stage
    -> retry_topic:topic_name
    -> dlq_topic:topic_name
    -> retry_policy:Kafka.Consumer.retry_policy
    -> group_id:string
    -> raw_msg:Kafka.Consumer.message
    -> publish:(target_topic:topic_name -> relay -> (unit, Kafka.Error.t) result)
    -> ack:(unit -> (unit, Kafka.Error.t) result)
    -> handler_error Kafka.Consumer.handler_result
    -> Kafka.Error.t Kafka.Consumer.handler_result
end

module Admin : sig
  type topic_partition_metadata =
    | Topic_not_found
    | Topic_partitions of
        { partitions : int
        ; replication_factor : int
        }

  type topic_partition_error

  val topic_partition_error_to_string : topic_partition_error -> string

  val decode_topic_partitions
    :  string
    -> (topic_partition_metadata, topic_partition_error) result
end

type 'a topic

type topic_durability =
  | Broker_default
  | Single_broker_loss

type config =
  { brokers : string list
  ; schema_registry_url : string
  ; admin_url : string
  ; linger_ms : int
  ; partitions : int
  ; topic_durability : topic_durability
  ; security : Kafka.Security.t
  }

module Confluent_wire : sig
  val encode : schema_id:int -> Yojson.Safe.t -> bytes
  val decode : bytes -> (int * string, string) result
end

val config_of_env : unit -> (config, error) result

type t

val create : config -> sw:Eio.Switch.t -> (t, error) result

val register
  :  t
  -> net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> (module MESSAGE with type t = 'a)
  -> ('a topic, error) result

val publish
  :  t
  -> 'a topic
  -> ?trace_ctx:Obs_trace.t
  -> 'a
  -> (unit, Kafka.Error.t) result Eio.Promise.t

type consumer_hooks =
  { kafka : Kafka.Consumer.hooks
  ; on_relay_publish :
      partition:int32 -> attempt:int -> outcome:[ `Published | `Failed ] -> unit
  }

val no_hooks : consumer_hooks

val consume
  :  t
  -> 'a topic
  -> group_id:string
  -> sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> ?hooks:consumer_hooks
  -> ?on_decode_error:
       (string
        -> raw_bytes:bytes option
        -> ack:(unit -> (unit, Kafka.Error.t) result)
        -> Kafka.Error.t Kafka.Consumer.handler_result)
  -> ?ot:Obs_eio.t
  -> ?stop:unit Eio.Promise.t
  -> handler:
       ('a
        -> ack:(unit -> (unit, Kafka.Error.t) result)
        -> trace_ctx:Obs_trace.t option
        -> Kafka.Error.t Kafka.Consumer.handler_result)
  -> unit
  -> (unit, Kafka.Error.t) result

type consume_partitioned_error =
  | Consumer_error of Kafka.Error.t
  | Partition_errors of (int32 * Kafka.Error.t) list

val consume_partitioned
  :  t
  -> 'a topic
  -> group_id:string
  -> sw:Eio.Switch.t
  -> net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> ?hooks:consumer_hooks
  -> ?decode_error_policy:decode_error_policy
  -> retry_policy:Kafka.Consumer.retry_policy
  -> ?consumer_properties:(string * string) list
  -> ?ot:Obs_eio.t
  -> ?stop:unit Eio.Promise.t
  -> handler:
       ('a
        -> ack:(unit -> (unit, Kafka.Error.t) result)
        -> trace_ctx:Obs_trace.t option
        -> handler_error Kafka.Consumer.handler_result)
  -> unit
  -> (unit, consume_partitioned_error) result
