(** High-level service layer for kafka-eio. Handles topic provisioning, schema
    registration, and typed message contracts. *)

(** Validated Kafka topic descriptor.

    Kafka-compatible names are 1-249 bytes, may contain ASCII letters, digits,
    [.], [_], and [-], and may not be [.] or [..]. *)
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

(** Validate and construct a Kafka topic descriptor. *)
val topic_name : string -> (topic_name, error) result

(** Like [topic_name], but raises [Invalid_argument] when the name is invalid.
    Intended for static topic declarations in event modules. *)
val topic_name_exn : string -> topic_name

(** Message contract — implement this for each topic your service owns. *)
module type MESSAGE = sig
  type t

  val topic_name : topic_name
  val schema : string (* JSON Schema string; registered on service startup *)
  val encode : t -> Yojson.Safe.t
  val decode : Yojson.Safe.t -> (t, string) result
end

type handler_error =
  | Retry
  | Dead_letter of string
  | Kafka_error of Kafka.Error.t

(** Schema compatibility checking against a live schema registry. Use in tests
    to catch breaking schema changes before deployment. *)
module Schema : sig
  (** Check whether a MESSAGE schema is compatible with the latest registered
      version for its topic. Returns [Ok ()] if compatible or if no version has
      been registered yet (new topic). Returns [Error _] if incompatible.

      Does not register the schema — safe to call in CI without side effects. *)
  val check
    :  net:_ Eio.Net.t
    -> clock:_ Eio.Time.clock
    -> registry_url:string
    -> (module MESSAGE)
    -> (unit, error) result

  (** Check a list of MESSAGE schemas, failing fast on the first incompatible
      one. Use in test_schemas.ml for each worker or service that owns topics.
  *)
  val check_all
    :  net:_ Eio.Net.t
    -> clock:_ Eio.Time.clock
    -> registry_url:string
    -> (module MESSAGE) list
    -> (unit, error) result

  type compatibility_response = { is_compatible : bool }
  type registration_response = { id : int }

  (** Decode a schema-registry compatibility-check response body. Exposed so
      tests can exercise the response codec directly instead of duplicating it —
      same rationale as [Confluent_wire]. *)
  val decode_compatibility_response : string -> (compatibility_response, string) result

  (** Decode a schema-registry registration response body. Same rationale as
      [decode_compatibility_response]. *)
  val decode_registration_response : string -> (registration_response, string) result
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
    | Forward_retry of
        { target : topic_name
        ; delay_s : float
        }
    | Forward_dlq of { target : topic_name }

  (** Read and validate the [X-Sol-Attempt]/[X-Sol-Retry-At] headers off a
      message forwarded to a retry topic. *)
  val parse_retry_metadata : (string * string option) list -> (int * float, string) result

  (** BUG-029: backoff (with jitter, capped) for the relay's in-process produce
      retry, keyed by produce attempt number (1-based). Not the user-facing
      retry_policy vocabulary FEAT-078 will introduce -- this only bounds the
      relay's own producer resilience. *)
  val produce_backoff_s : int -> float

  (** [retry_produce ~max_attempts ~backoff_s ~sleep ~on_retry ~produce ()]
      retries [produce] up to [max_attempts] times, calling
      [on_retry ~attempt ~error] and [sleep (backoff_s attempt)] between
      attempts. Exposed so the retry-count and give-up behavior can be tested
      with stubbed [produce]/[sleep] (BUG-029). *)
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

  (** A relay command: publish [source] to some target topic, carrying the
      already-fully-resolved [headers] to send (no further header policy is
      decided at publish time) plus [attempt]/[delay_s] for metrics
      ([on_retry]/[on_relay_publish]) — not for serialization. Built
      exclusively by [retry_message]/[dead_letter_message]/
      [retry_decode_failure_message] below; nothing else should construct one
      by hand. *)
  type relay =
    { source : Kafka.Consumer.message
    ; headers : (string * string option) list
    ; attempt : int
    ; delay_s : float
    }

  (** A scheduled retry: strips any stale [X-Sol-*] headers from [raw_msg] and
      stamps fresh [X-Sol-Attempt]/[X-Sol-Retry-At] ([delay_s] from now). *)
  val retry_message
    :  raw_msg:Kafka.Consumer.message
    -> attempt:int
    -> delay_s:float
    -> relay

  (** Retry budget exhausted: a {!retry_message} with [delay_s = 0.0] (dead
      letters are immediate, not scheduled), plus [X-Sol-Origin-Group]
      (BUG-030: dead-lettering is a statement about [group_id]'s processing
      attempt, not an intrinsic property of the source event). *)
  val dead_letter_message
    :  raw_msg:Kafka.Consumer.message
    -> attempt:int
    -> group_id:string
    -> relay

  (** A retry record that couldn't even be decoded: preserves [raw_msg]'s
      existing headers untouched (this is not another scheduled attempt), and
      appends a decode diagnostic plus [X-Sol-Origin-Group] (BUG-030, see
      {!dead_letter_message}). *)
  val retry_decode_failure_message
    :  raw_msg:Kafka.Consumer.message
    -> attempt:int
    -> decode_error:string
    -> group_id:string
    -> relay

  (** Execute the side-effecting part of a retry decision: build the relay
      command for the chosen action (for [Forward_retry]/[Forward_dlq]),
      [publish] it, then [ack]. [Ack] skips straight to acking. [group_id] is
      only used on the [Forward_dlq] path (BUG-030's [X-Sol-Origin-Group]). *)
  val execute_action
    :  group_id:string
    -> retry_action
    -> raw_msg:Kafka.Consumer.message
    -> attempt:int
    -> publish:(target_topic:topic_name -> relay -> (unit, Kafka.Error.t) result)
    -> ack:(unit -> (unit, Kafka.Error.t) result)
    -> (unit, Kafka.Error.t) result

  (** On a retry-topic decode failure, publish the raw retry record (with
      decode diagnostics attached) to the DLQ rather than reaching the
      source-path [on_decode_error] skip-and-ack contract (BUG-028). Always
      targets the DLQ, so it builds its own relay command rather than going
      through {!execute_action}'s [retry_action] dispatch. *)
  val route_retry_decode_error
    :  dlq_topic:topic_name
    -> raw_msg:Kafka.Consumer.message
    -> attempt:int
    -> decode_error:string
    -> group_id:string
    -> publish:(target_topic:topic_name -> relay -> (unit, Kafka.Error.t) result)
    -> ack:(unit -> (unit, Kafka.Error.t) result)
    -> (unit, Kafka.Error.t) result

  (** The one canonical retry/DLQ topic name: [<source>.<canonical-group>.<suffix>]
      ([suffix] is ["retry"] or ["dlq"]). [group_id] is sanitized to
      alphanumerics and ['-'] and, if long enough to risk Kafka's 249-byte
      topic name limit, truncated with a content-hash suffix (BUG-030: retry
      and DLQ topic identity must include consumer-group identity, or
      independent groups on the same source topic consume each other's
      retries/dead letters). Never reconstruct a retry/DLQ topic name any
      other way. *)
  val relay_topic_name : source:string -> group_id:string -> suffix:string -> string
end

(** Redpanda admin API topic-metadata parsing, backing [register]'s
    partition-count guard. Exposed so tests can exercise the response codec
    directly, the same rationale as [Schema]'s decode functions. *)
module Admin : sig
  (** Partition count for an existing topic, or [Topic_not_found] (HTTP 404). *)
  type topic_partition_metadata =
    | Topic_not_found
    | Topic_partitions of
        { partitions : int
        ; replication_factor : int
        }

  (** Opaque — every case is a distinct admin-API failure shape; callers only
      ever need [topic_partition_error_to_string], never to match a specific
      case. *)
  type topic_partition_error

  val topic_partition_error_to_string : topic_partition_error -> string

  (** Parse a Redpanda admin API topic-metadata response body. *)
  val decode_topic_partitions
    :  string
    -> (topic_partition_metadata, topic_partition_error) result
end

(** Opaque handle to a provisioned, schema-registered topic. Obtained via
    [register]. Carries the schema ID for wire-format encoding. *)
type 'a topic

type topic_durability =
  | Broker_default
  | Single_broker_loss

type config =
  { brokers : string list
  ; schema_registry_url : string (** e.g. "http://localhost:8081" *)
  ; admin_url : string (** Redpanda admin API, e.g. "http://localhost:9644" *)
  ; linger_ms : int (** produce batch window in ms; 50 is a good default *)
  ; partitions : int (** partition count for auto-provisioned topics *)
  ; topic_durability : topic_durability
  ; security : Kafka.Security.t
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
  (** Encode a JSON value into Confluent wire format. Returns a [bytes] value
      ready to pass to the Kafka producer. *)
  val encode : schema_id:int -> Yojson.Safe.t -> bytes

  (** Decode a Confluent wire-format message.
      - [Error "wire format: message too short"] if the payload is fewer than 5
        bytes.
      - [Error "wire format: invalid magic byte"] if the first byte is not
        [0x00].
      - [Ok (schema_id, json_string)] on success. *)
  val decode : bytes -> (int * string, string) result
end

(** Build a [config] from environment variables with sensible local-dev
    defaults.
    - [KAFKA_BROKERS] — comma-separated broker addresses (default:
      ["localhost:9092"])
    - [SCHEMA_REGISTRY_URL] — schema registry HTTP URL (default:
      ["http://localhost:8081"])
    - [REDPANDA_ADMIN_URL] — Redpanda admin API URL (default:
      ["http://localhost:9644"])
    - [SOL_KAFKA_DURABILITY] — ["broker-default" | "single-broker-loss"]
      (default: ["broker-default"])
    - [KAFKA_SECURITY_PROTOCOL] —
      ["plaintext" | "ssl" | "sasl_plaintext" | "sasl_ssl"] (default:
      ["plaintext"])
    - [KAFKA_SSL_CA_LOCATION] — path to CA cert bundle (optional)
    - [KAFKA_SASL_MECHANISM] — e.g. ["SCRAM-SHA-256"] (optional)
    - [KAFKA_SASL_USERNAME] / [KAFKA_SASL_PASSWORD] — SASL credentials
      (optional) Returns [Error _] when a supplied Kafka security setting is
      malformed or incomplete. [linger_ms = 50], [partitions = 1]. *)
val config_of_env : unit -> (config, error) result

type t

(** [create cfg ~sw] creates a service handle with an underlying producer. Does
    not provision topics or register schemas — call [register] for that. *)
val create : config -> sw:Eio.Switch.t -> (t, error) result

(** [register svc ~net ~clock (module M)] provisions M's topic via the Redpanda
    admin HTTP API and registers its JSON schema with the schema registry.
    Returns a typed topic handle for use with [publish] and [consume]. *)
val register
  :  t
  -> net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> (module MESSAGE with type t = 'a)
  -> ('a topic, error) result

(** [publish svc topic ?trace_ctx msg] encodes [msg] in Confluent wire format
    and produces it to the broker. When [trace_ctx] is provided it is serialised
    as a W3C [traceparent] Kafka message header, propagating the trace to
    consumers. Returns a promise that resolves on broker acknowledgement. *)
val publish
  :  t
  -> 'a topic
  -> ?trace_ctx:Obs_trace.t
  -> 'a
  -> (unit, Kafka.Error.t) result Eio.Promise.t

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
val consume
  :  t
  -> 'a topic
  -> group_id:string
  -> sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> ?on_ready:(unit -> unit)
  -> ?on_assigned:(unit -> unit)
  -> ?on_revoked:(unit -> unit)
  -> ?on_poll:(unit -> unit)
  -> ?on_decode_error:
       (string
        -> raw_bytes:bytes option
        -> ack:(unit -> (unit, Kafka.Error.t) result)
        -> Kafka.Error.t Kafka.Consumer.handler_result)
  -> ?ot:Obs_eio.t
  -> handler:
       ('a
        -> ack:(unit -> (unit, Kafka.Error.t) result)
        -> trace_ctx:Obs_trace.t option
        -> Kafka.Error.t Kafka.Consumer.handler_result)
  -> unit
  -> (unit, Kafka.Error.t) result

(** How [consume_partitioned] should handle transient handler failures. Both
    variants share one [retry_policy] vocabulary (FEAT-078) — [base_delay_s],
    [max_delay_s], [max_attempts], [jitter_ratio] — but are not
    feature-equivalent: exhaustion disposition is strategy-specific by
    design (see each variant below), and there is no implicit default —
    every call site must state which strategy, and which policy, it wants.

    - [In_memory retry] — exponential back-off sleep inside the partition
      fiber with the given [retry_policy] (delay = [base_delay_s *
      2^(attempt-1)], jittered by [jitter_ratio], clamped to [max_delay_s]).
      Simple, zero infra. Pauses that Kafka partition for the retry delay;
      vulnerable to rebalance preempting the sleep window. On exhaustion (or
      on a handler's [Dead_letter], which [In_memory] cannot route to a DLQ
      it doesn't have): terminal failure, the message is left unacknowledged,
      and the partition/worker fails under normal consumer semantics — never
      acknowledged-and-discarded (BUG-028's invariant, restated for
      FEAT-078's [Dead_letter]-without-DLQ case).

    - [Retry_topics retry] — on failure the raw message bytes are published
      to the group-scoped retry topic (BUG-030) with [X-Sol-Attempt] /
      [X-Sol-Retry-At] headers, and the original offset is immediately
      committed. A background retry consumer (group [<group_id>-sol-retry])
      subscribes to that topic, waits until [X-Sol-Retry-At], then re-runs
      the handler. That wait blocks every later record sharing the retry
      partition, including unrelated keys. Republishing gives the retry a
      later Kafka offset, so it can execute after records that originally
      followed it, including records with the same key. In steady state the
      extra head-of-line delay is bounded roughly by [max_delay_s]; under
      backlog or overload it is unbounded.
      After [retry.max_attempts] total failures, or on a handler's
      [Dead_letter], the message is routed to the group-scoped DLQ topic and
      the retry offset is acked only once that publish succeeds.
      [retry.max_attempts] must be at least 1. Both topics are
      auto-provisioned before consumption starts; provisioning or
      retry-consumer startup failures return [Consumer_error] instead of
      running with a partially installed retry strategy. *)
type retry_strategy =
  | In_memory of Kafka.Consumer.retry_policy
  | Retry_topics of Kafka.Consumer.retry_policy

type consume_partitioned_error =
  | Consumer_error of Kafka.Error.t
  (** The consumer never started (create failed) or [consume_partitioned]
          rejected its own arguments before consuming began — not tied to any
          one partition. *)
  | Partition_errors of (int32 * Kafka.Error.t) list
  (** Every partition that exhausted its retry budget, not just one —
          [kafka-eio]'s own [Handler_errors] list is preserved in full rather
          than collapsed to a single partition's error. Non-empty. *)

(** [consume_partitioned svc topic ~group_id ~sw ~net ~clock ...] is like [consume]
    but routes each message to a dedicated per-partition fiber. A partition's
    in-memory retry sleep blocks only that partition; other partitions continue
    unaffected. During the sleep the partition is paused at the librdkafka level
    so no messages accumulate in its stream buffer.

    [retry_strategy] selects the failure-handling mode; see [retry_strategy].
    Mandatory, not optional (FEAT-078): a missing retry strategy must never
    become an implicit fallback discovered only when a handler first fails.
    Pass [on_retry] to emit metrics on each retry event regardless of mode.
    [on_relay_publish] (Retry_topics only, BUG-029) distinguishes a scheduled
    retry ([on_retry]) from the relay's own publish to the retry/DLQ topic
    actually succeeding or being exhausted -- see {!Retry_topics}'s doc. *)
val consume_partitioned
  :  t
  -> 'a topic
  -> group_id:string
  -> sw:Eio.Switch.t
  -> net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> ?on_ready:(unit -> unit)
  -> ?on_assigned:(unit -> unit)
  -> ?on_revoked:(unit -> unit)
  -> ?on_poll:(unit -> unit)
  -> ?on_decode_error:
       (string
        -> raw_bytes:bytes option
        -> ack:(unit -> (unit, Kafka.Error.t) result)
        -> Kafka.Error.t Kafka.Consumer.handler_result)
  -> retry_strategy:retry_strategy
  -> ?on_retry:(partition:int32 -> attempt:int -> delay_s:float -> unit)
  -> ?on_relay_publish:
       (partition:int32 -> attempt:int -> outcome:[ `Published | `Failed ] -> unit)
  -> ?ot:Obs_eio.t
  -> handler:
       ('a
        -> ack:(unit -> (unit, Kafka.Error.t) result)
        -> trace_ctx:Obs_trace.t option
        -> handler_error Kafka.Consumer.handler_result)
  -> unit
  -> (unit, consume_partitioned_error) result
