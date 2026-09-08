(** Shared types and topic/decode-error helpers underlying [Kafka_service].
    Split out from [kafka_service.ml] so [Kafka_service_schema] and
    [Kafka_service_retry_topics] can depend on the shared [t]/[topic]/
    [config] types without a circular dependency on [Kafka_service] itself.
    [Kafka_service] re-exports the public pieces of this module directly —
    see its [.mli] for the documented, stable API. *)

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

type 'a topic = {
  name      : topic_name;
  schema_id : int;
  encode    : 'a -> Yojson.Safe.t;
  decode    : Yojson.Safe.t -> ('a, string) result;
}

type config = {
  brokers             : string list;
  schema_registry_url : string;
  admin_url           : string;
  linger_ms           : int;
  partitions          : int;
  security            : Kafka.Security.t;
}

type t = {
  producer            : Kafka.Producer.t;
  brokers             : string list;
  schema_registry_url : string;
  admin_url           : string;
  partitions          : int;
  security            : Kafka.Security.t;
}

type consume_partitioned_error =
  | Consumer_error of Kafka.Error.t
  | Partition_errors of (int32 * Kafka.Error.t) list

val ensure_topic
  :  Kafka.Producer.t
  -> topic_name:string
  -> partitions:int
  -> (unit, Kafka.Error.t) result
(** Provision [topic_name] via the producer's admin client if it doesn't
    already exist. *)

(** Partition count for an existing topic, or [Topic_not_found] (HTTP 404). *)
type topic_partition_metadata =
  | Topic_not_found
  | Topic_partitions of int

(** Opaque — every case is a distinct admin-API failure shape; callers only
    ever need [topic_partition_error_to_string], never to match a specific
    case. *)
type topic_partition_error

val topic_partition_error_to_string : topic_partition_error -> string

val decode_topic_partitions
  :  string
  -> (topic_partition_metadata, topic_partition_error) result
(** Parse a Redpanda admin API topic-metadata response body. *)

val query_topic_partitions
  :  _ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> admin_url:string
  -> topic_name:string
  -> (topic_partition_metadata, topic_partition_error) result
(** [GET {admin_url}/v1/topics/{topic_name}], then [decode_topic_partitions]. *)

val wrap_on_decode_error
  :  ot:Obs_eio.t option
  -> topic_name:string
  -> (string -> raw_bytes:bytes option -> ack:(unit -> (unit, Kafka.Error.t) result) -> Kafka.Error.t Kafka.Consumer.handler_result)
  -> (string -> raw_bytes:bytes option -> ack:(unit -> (unit, Kafka.Error.t) result) -> Kafka.Error.t Kafka.Consumer.handler_result)
(** Wrap a caller-supplied [on_decode_error] so every decode error also
    increments a counter and logs through [ot] (when given) before
    delegating to the caller's handler. *)
