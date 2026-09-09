(** High-level service layer for kafka-eio. Handles topic provisioning, schema
    registration, and typed message contracts. *)

type topic_name
(** Validated Kafka topic descriptor.

    Kafka-compatible names are 1-249 bytes, may contain ASCII letters, digits,
    [.], [_], and [-], and may not be [.] or [..]. *)

type error =
  | Invalid_topic_name of string * string
  | Config of string
  | Create of Kafka.Error.t
  | Topic_metadata of topic_name * string
  | Partition_count_reduction of {
      topic_name : topic_name;
      current : int;
      requested : int;
    }
  | Provision_topic of topic_name * Kafka.Error.t
  | Schema_registry of topic_name * string

val topic_name_to_string : topic_name -> string
val error_to_string : error -> string

val topic_name : string -> (topic_name, error) result
(** Validate and construct a Kafka topic descriptor. *)

val topic_name_exn : string -> topic_name
(** Like [topic_name], but raises [Invalid_argument] when the name is invalid.
    Intended for static topic declarations in event modules. *)

(** Message contract — implement this for each topic your service owns. *)
module type MESSAGE = sig
  type t

  val topic_name : topic_name
  val schema : string (* JSON Schema string; registered on service startup *)
  val encode : t -> Yojson.Safe.t
  val decode : Yojson.Safe.t -> (t, string) result
end

(** Schema compatibility checking against a live schema registry. Use in tests
    to catch breaking schema changes before deployment. *)
module Schema : sig
  val check :
    net:_ Eio.Net.t ->
    clock:_ Eio.Time.clock ->
    registry_url:string ->
    (module MESSAGE) ->
    (unit, error) result
  (** Check whether a MESSAGE schema is compatible with the latest registered
      version for its topic. Returns [Ok ()] if compatible or if no version has
      been registered yet (new topic). Returns [Error _] if incompatible.

      Does not register the schema — safe to call in CI without side effects. *)

  val check_all :
    net:_ Eio.Net.t ->
    clock:_ Eio.Time.clock ->
    registry_url:string ->
    (module MESSAGE) list ->
    (unit, error) result
  (** Check a list of MESSAGE schemas, failing fast on the first incompatible
      one. Use in test_schemas.ml for each worker or service that owns topics.
  *)

  type compatibility_response = { is_compatible : bool }
  type registration_response = { id : int }

  val decode_compatibility_response :
    string -> (compatibility_response, string) result
  (** Decode a schema-registry compatibility-check response body. Exposed so
      tests can exercise the response codec directly instead of duplicating it —
      same rationale as [Confluent_wire]. *)

  val decode_registration_response :
    string -> (registration_response, string) result
  (** Decode a schema-registry registration response body. Same rationale as
      [decode_compatibility_response]. *)
end

(** Retry/DLQ routing decisions for [consume_partitioned]'s [Retry_topics]
    strategy (see [retry_strategy] below). Exposed so tests can exercise the
    routing decision and header codec directly, the same rationale as [Schema]'s
    decode functions. Only [consume_partitioned] itself calls into the
    side-effecting parts of this during normal operation. *)
module Retry_topics : sig
  (** Typed outcome for a single retry-routing decision. *)
  type retry_action =
    | Ack
    | Forward_retry of { target : topic_name; delay_s : float }
    | Forward_dlq of { target : topic_name }

  val parse_retry_metadata :
    (string * string option) list -> (int * float, string) result
  (** Read and validate the [X-Sol-Attempt]/[X-Sol-Retry-At] headers off a
      message forwarded to a retry topic. *)

  val execute_action :
    retry_action ->
    raw_msg:Kafka.Consumer.message ->
    attempt:int ->
    publish_raw:
      (target_topic:topic_name ->
      attempt:int ->
      raw_bytes:bytes option ->
      headers:(string * string option) list ->
      delay_s:float ->
      partition:int32 ->
      (unit, Kafka.Error.t) result) ->
    ack:(unit -> (unit, Kafka.Error.t) result) ->
    (unit, Kafka.Error.t) result
  (** Execute the side-effecting part of a retry decision: publish to the target
      topic (for [Forward_retry]/[Forward_dlq]) then [ack]. [Ack] skips straight
      to acking. *)
end

(** Redpanda admin API topic-metadata parsing, backing [register]'s
    partition-count guard. Exposed so tests can exercise the response codec
    directly, the same rationale as [Schema]'s decode functions. *)
module Admin : sig
  (** Partition count for an existing topic, or [Topic_not_found] (HTTP 404). *)
  type topic_partition_metadata = Topic_not_found | Topic_partitions of int

  type topic_partition_error
  (** Opaque — every case is a distinct admin-API failure shape; callers only
      ever need [topic_partition_error_to_string], never to match a specific
      case. *)

  val topic_partition_error_to_string : topic_partition_error -> string

  val decode_topic_partitions :
    string -> (topic_partition_metadata, topic_partition_error) result
  (** Parse a Redpanda admin API topic-metadata response body. *)
end

type 'a topic
(** Opaque handle to a provisioned, schema-registered topic. Obtained via
    [register]. Carries the schema ID for wire-format encoding. *)

type config = {
  brokers : string list;
  schema_registry_url : string;  (** e.g. "http://localhost:8081" *)
  admin_url : string;  (** Redpanda admin API, e.g. "http://localhost:9644" *)
  linger_ms : int;  (** produce batch window in ms; 50 is a good default *)
  partitions : int;  (** partition count for auto-provisioned topics *)
  security : Kafka.Security.t;
      (** Transport security for broker connections. Use
          [Kafka.Security.default] for local dev. Production: set
          [KAFKA_SECURITY_PROTOCOL=sasl_ssl] and supply SASL credentials via
          env. *)
}

(** Confluent wire-format codec.

    Wire layout: [0x00] (magic byte) ++ 4 bytes big-endian schema ID ++ JSON
    payload.

    Exposed so that tests can exercise the production codec directly instead of
    duplicating encode/decode logic. *)
module Confluent_wire : sig
  val encode : schema_id:int -> Yojson.Safe.t -> bytes
  (** Encode a JSON value into Confluent wire format. Returns a [bytes] value
      ready to pass to the Kafka producer. *)

  val decode : bytes -> (int * string, string) result
  (** Decode a Confluent wire-format message.
      - [Error "wire format: message too short"] if the payload is fewer than 5
        bytes.
      - [Error "wire format: invalid magic byte"] if the first byte is not
        [0x00].
      - [Ok (schema_id, json_string)] on success. *)
end

val config_of_env : unit -> (config, error) result
(** Build a [config] from environment variables with sensible local-dev
    defaults.
    - [KAFKA_BROKERS] — comma-separated broker addresses (default:
      ["localhost:9092"])
    - [SCHEMA_REGISTRY_URL] — schema registry HTTP URL (default:
      ["http://localhost:8081"])
    - [REDPANDA_ADMIN_URL] — Redpanda admin API URL (default:
      ["http://localhost:9644"])
    - [KAFKA_SECURITY_PROTOCOL] —
      ["plaintext" | "ssl" | "sasl_plaintext" | "sasl_ssl"] (default:
      ["plaintext"])
    - [KAFKA_SSL_CA_LOCATION] — path to CA cert bundle (optional)
    - [KAFKA_SASL_MECHANISM] — e.g. ["SCRAM-SHA-256"] (optional)
    - [KAFKA_SASL_USERNAME] / [KAFKA_SASL_PASSWORD] — SASL credentials
      (optional) Returns [Error _] when a supplied Kafka security setting is
      malformed or incomplete. [linger_ms = 50], [partitions = 1]. *)

type t

val create : config -> sw:Eio.Switch.t -> (t, error) result
(** [create cfg ~sw] creates a service handle with an underlying producer. Does
    not provision topics or register schemas — call [register] for that. *)

val register :
  t ->
  net:_ Eio.Net.t ->
  clock:_ Eio.Time.clock ->
  (module MESSAGE with type t = 'a) ->
  ('a topic, error) result
(** [register svc ~net ~clock (module M)] provisions M's topic via the Redpanda
    admin HTTP API and registers its JSON schema with the schema registry.
    Returns a typed topic handle for use with [publish] and [consume]. *)

val publish :
  t ->
  'a topic ->
  ?trace_ctx:Obs_trace.t ->
  'a ->
  (unit, Kafka.Error.t) result Eio.Promise.t
(** [publish svc topic ?trace_ctx msg] encodes [msg] in Confluent wire format
    and produces it to the broker. When [trace_ctx] is provided it is serialised
    as a W3C [traceparent] Kafka message header, propagating the trace to
    consumers. Returns a promise that resolves on broker acknowledgement. *)

val consume :
  t ->
  'a topic ->
  group_id:string ->
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  ?on_ready:(unit -> unit) ->
  ?on_decode_error:
    (string ->
    raw_bytes:bytes option ->
    ack:(unit -> (unit, Kafka.Error.t) result) ->
    Kafka.Error.t Kafka.Consumer.handler_result) ->
  ?ot:Obs_eio.t ->
  handler:
    ('a ->
    ack:(unit -> (unit, Kafka.Error.t) result) ->
    trace_ctx:Obs_trace.t option ->
    Kafka.Error.t Kafka.Consumer.handler_result) ->
  unit ->
  (unit, Kafka.Error.t) result
(** [consume svc topic ~group_id ~sw ?on_ready ?on_decode_error ~handler]
    subscribes to the topic and calls [handler] for each successfully decoded
    message. New consumer groups start from the earliest retained offset.
    [ack ()] commits the offset after processing.

    [trace_ctx] in the handler is the parsed [traceparent] header from the
    incoming Kafka message, or [None] if the message carries no trace header.
    Pass it as [?parent:trace_ctx] to [Obs_eio.with_span] to link the consumer
    span to the upstream producer trace.

    [on_ready] is called exactly once when the broker assigns partitions to this
    consumer. Use it to signal readiness to a test or health-check instead of
    sleeping for a fixed rebalance timeout.

    [on_decode_error] is called when a message cannot be decoded (bad wire
    format, failed JSON parse, or failed MESSAGE.decode). Default: log the
    error, ack the message, and continue consuming.

    Returns when [handler] returns [Error]. *)

(** How [consume_partitioned] should handle transient handler failures.

    - [In_memory retry] (default) — exponential back-off sleep inside the
      partition fiber with the given [retry_policy]. Simple, zero infra.
      Vulnerable to rebalance preempting the sleep window.

    - [Retry_topics { max_attempts }] — on failure the raw message bytes are
      published to [<topic>-retry] with [X-Sol-Attempt] / [X-Sol-Retry-At]
      headers, and the original offset is immediately committed. A background
      retry consumer (group [<group_id>-sol-retry]) subscribes to
      [<topic>-retry], waits until [X-Sol-Retry-At], then re-runs the handler.
      After [max_attempts] total failures the message is routed to
      [<topic>-dlq]. [max_attempts] must be at least 1. Both topics are
      auto-provisioned before consumption starts; provisioning or retry-consumer
      startup failures return [Consumer_error] instead of running with a
      partially installed retry strategy. *)
type retry_strategy =
  | In_memory of Kafka.Consumer.retry_policy
  | Retry_topics of { max_attempts : int }

val default_retry_strategy : retry_strategy
(** [In_memory Kafka.Consumer.default_retry] — in-process exponential backoff,
    indefinite retries. Suitable for transient failures in low-traffic topics.
*)

type consume_partitioned_error =
  | Consumer_error of Kafka.Error.t
      (** The consumer never started (create failed) or [consume_partitioned]
          rejected its own arguments before consuming began — not tied to any
          one partition. *)
  | Partition_errors of (int32 * Kafka.Error.t) list
      (** Every partition that exhausted its retry budget, not just one —
          [kafka-eio]'s own [Handler_errors] list is preserved in full rather
          than collapsed to a single partition's error. Non-empty. *)

val consume_partitioned :
  t ->
  'a topic ->
  group_id:string ->
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  ?on_ready:(unit -> unit) ->
  ?on_decode_error:
    (string ->
    raw_bytes:bytes option ->
    ack:(unit -> (unit, Kafka.Error.t) result) ->
    Kafka.Error.t Kafka.Consumer.handler_result) ->
  ?retry_strategy:retry_strategy ->
  ?on_retry:(partition:int32 -> attempt:int -> delay_s:float -> unit) ->
  ?ot:Obs_eio.t ->
  handler:
    ('a ->
    ack:(unit -> (unit, Kafka.Error.t) result) ->
    trace_ctx:Obs_trace.t option ->
    Kafka.Error.t Kafka.Consumer.handler_result) ->
  unit ->
  (unit, consume_partitioned_error) result
(** [consume_partitioned svc topic ~group_id ~sw ~clock ...] is like [consume]
    but routes each message to a dedicated per-partition fiber. A partition's
    in-memory retry sleep blocks only that partition; other partitions continue
    unaffected. During the sleep the partition is paused at the librdkafka level
    so no messages accumulate in its stream buffer.

    [retry_strategy] selects the failure-handling mode; see [retry_strategy].
    Pass [on_retry] to emit metrics on each retry event regardless of mode. *)
