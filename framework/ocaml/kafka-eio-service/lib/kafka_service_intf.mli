type topic_name

val topic_name : string -> (topic_name, string) result
val topic_name_exn : string -> topic_name
val topic_name_to_string : topic_name -> string

module type MESSAGE = sig
  type t

  val topic_name : topic_name
  val schema : string
  val encode : t -> Yojson.Safe.t
  val decode : Yojson.Safe.t -> (t, string) result
end

type 'a topic =
  { name : topic_name
  ; schema_id : int
  ; encode : 'a -> Yojson.Safe.t
  ; decode : Yojson.Safe.t -> ('a, string) result
  }

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

type t =
  { producer : Kafka.Producer.t
  ; brokers : string list
  ; schema_registry_url : string
  ; admin_url : string
  ; partitions : int
  ; topic_durability : topic_durability
  ; security : Kafka.Security.t
  }

type consume_partitioned_error =
  | Consumer_error of Kafka.Error.t
  | Partition_errors of (int32 * Kafka.Error.t) list

type handler_error =
  | Retry
  | Dead_letter of string
  | Kafka_error of Kafka.Error.t

type decode_error_policy =
  | Route_to_dlq
  | Ack_and_drop

val ensure_topic
  :  Kafka.Producer.t
  -> topic_name:string
  -> partitions:int
  -> topic_durability:topic_durability
  -> (unit, Kafka.Error.t) result

type topic_partition_metadata =
  | Topic_not_found
  | Topic_partitions of
      { partitions : int
      ; replication_factor : int
      }

val topic_has_required_replication : topic_durability -> topic_partition_metadata -> bool

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

val observe_decode_error
  :  ot:Obs_eio.t option
  -> topic_name:string
  -> string
  -> raw_bytes:bytes option
  -> disposition:[ `Dropped | `Dead_lettered ]
  -> unit

val ack_and_drop_decode_error
  :  string
  -> raw_bytes:bytes option
  -> ack:(unit -> (unit, Kafka.Error.t) result)
  -> Kafka.Error.t Kafka.Consumer.handler_result

val wrap_on_decode_error
  :  ot:Obs_eio.t option
  -> topic_name:string
  -> (string
      -> raw_bytes:bytes option
      -> ack:(unit -> (unit, Kafka.Error.t) result)
      -> Kafka.Error.t Kafka.Consumer.handler_result)
  -> string
  -> raw_bytes:bytes option
  -> ack:(unit -> (unit, Kafka.Error.t) result)
  -> Kafka.Error.t Kafka.Consumer.handler_result
