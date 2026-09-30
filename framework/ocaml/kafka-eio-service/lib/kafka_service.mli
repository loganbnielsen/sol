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
  val partitions : int
  val key : t -> string option
  val encode : t -> Yojson.Safe.t
  val decode : Yojson.Safe.t -> (t, string) result
end

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

  val register
    :  net:_ Eio.Net.t
    -> clock:_ Eio.Time.clock
    -> registry_url:string
    -> (module MESSAGE)
    -> (int, error) result

  val resolve
    :  net:_ Eio.Net.t
    -> clock:_ Eio.Time.clock
    -> registry_url:string
    -> (module MESSAGE)
    -> (int, error) result

  type compatibility_response = { is_compatible : bool }
  type registration_response = { id : int }

  val is_subject_not_found : string -> bool
  val decode_compatibility_response : string -> (compatibility_response, string) result
  val decode_registration_response : string -> (registration_response, string) result
end

module Contract : sig
  val projection : (string * (module MESSAGE)) list -> Yojson.Safe.t
end

module Dlq : sig
  type relay =
    { source : Kafka.Consumer.message
    ; headers : (string * string option) list
    }

  val sanitize_group_id : string -> string
  val canonical_group_segment : string -> string
  val dlq_topic_name : source:string -> group_id:string -> string

  val decode_failure_message
    :  raw_msg:Kafka.Consumer.message
    -> decode_error:string
    -> group_id:string
    -> relay

  val route_decode_error
    :  dlq_topic:string
    -> raw_msg:Kafka.Consumer.message
    -> decode_error:string
    -> group_id:string
    -> publish:(target_topic:string -> relay -> (unit, Kafka.Error.t) result)
    -> ack:(unit -> (unit, Kafka.Error.t) result)
    -> (unit, Kafka.Error.t) result
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

  val query_topic_partitions
    :  _ Eio.Net.t
    -> clock:_ Eio.Time.clock
    -> admin_url:string
    -> topic_name:string
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

val consume
  :  t
  -> 'a topic
  -> group_id:string
  -> sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> ?hooks:Kafka.Consumer.hooks
  -> ?decode_error_policy:decode_error_policy
  -> ?ot:Obs_eio.t
  -> ?stop:unit Eio.Promise.t
  -> handler:
       ('a
        -> ack:(unit -> (unit, Kafka.Error.t) result)
        -> trace_ctx:Obs_trace.t option
        -> Kafka.Error.t Kafka.Consumer.handler_result)
  -> unit
  -> (unit, Kafka.Error.t) result
