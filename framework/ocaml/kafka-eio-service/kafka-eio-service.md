# kafka-eio-service — Design Document

## Overview

High-level service layer for the Sol Kafka stack. Sits on top of `kafka-eio-producer`
and `kafka-eio-consumer` and adds:

- **Typed message contracts** — each topic has an OCaml type with encode/decode
- **Schema registry** — schemas are registered with Redpanda's built-in schema registry
  on startup; producers can't publish messages with breaking schema changes
- **Topic auto-provisioning** — topics are created via the Redpanda admin API on startup
  if they don't exist
- **Confluent wire format** — every message is framed with a magic byte and schema ID
  so any Confluent-compatible consumer can decode it
- **Batched delivery** — `linger_ms` (default 50ms) batches outbound messages for
  throughput without adding application complexity

## Package Structure

```
kafka-eio-service/
  lib/
    kafka_service.ml   # full implementation + internal HTTP client
    kafka_service.mli  # public API
  test/
    test_kafka_service.ml
```

All HTTP client, schema registry, and admin API logic lives inside `kafka_service.ml`
as private helpers. No extra packages beyond `yojson` and the existing Eio ecosystem.

## Message Contract

Users define a module satisfying `MESSAGE` for each topic they own:

```ocaml
module PaymentEvent : Kafka_service.MESSAGE = struct
  type t = {
    payment_id : string;
    amount_cents : int;
    currency : string;
  }

  let topic_name =
    Kafka_service.topic_name_exn "payments"

  let schema = {|{
    "type": "object",
    "properties": {
      "payment_id":    { "type": "string" },
      "amount_cents":  { "type": "integer" },
      "currency":      { "type": "string" }
    },
    "required": ["payment_id", "amount_cents", "currency"]
  }|}

  let encode t = `Assoc [
    ("payment_id",    `String t.payment_id);
    ("amount_cents",  `Int    t.amount_cents);
    ("currency",      `String t.currency);
  ]

  let decode = function
    | `Assoc fields ->
      (match List.assoc_opt "payment_id" fields,
             List.assoc_opt "amount_cents" fields,
             List.assoc_opt "currency" fields with
       | Some (`String payment_id), Some (`Int amount_cents), Some (`String currency) ->
         Ok { payment_id; amount_cents; currency }
       | _ -> Error "missing required fields")
    | _ -> Error "expected object"
end
```

## Configuration

```ocaml
type topic_durability =
  | Broker_default
  | Single_broker_loss

type config =
  { brokers : string list
  ; schema_registry_url : string       (* "http://localhost:8081" *)
  ; admin_url : string                 (* Redpanda admin API, e.g. "http://localhost:9644" *)
  ; linger_ms : int                    (* batch window; 50ms recommended *)
  ; partitions : int                   (* partition count for auto-provisioned topics *)
  ; topic_durability : topic_durability
  ; security : Kafka.Security.t
  (* Transport security. Use Kafka.Security.default for local dev. With
     config_of_env it comes from KAFKA_SECURITY_PROTOCOL, which is required. *)
  }
```

**Preferred: build config from environment variables** using `config_of_env`:

```ocaml
val config_of_env : unit -> (config, error) result
(* Reads:
   KAFKA_BROKERS           — comma-separated broker addresses (required)
   SCHEMA_REGISTRY_URL     — schema registry HTTP URL (required)
   REDPANDA_ADMIN_URL      — Redpanda admin API URL   (required)
   None of the three defaults to localhost (BUG-055); an unset one is an Error
   naming every missing variable.
   SOL_KAFKA_DURABILITY    — "broker-default" | "single-broker-loss"
   KAFKA_SECURITY_PROTOCOL — "plaintext" | "ssl" | "sasl_plaintext" | "sasl_ssl"
                             REQUIRED, no default (SEC-007); Sol manifests set it
   KAFKA_SSL_CA_LOCATION   — path to CA cert bundle (optional)
   KAFKA_SASL_MECHANISM    — e.g. "SCRAM-SHA-256" (optional)
   KAFKA_SASL_USERNAME / KAFKA_SASL_PASSWORD — SASL credentials (optional)
   linger_ms = 50, partitions = 1)
(* Returns Error when KAFKA_SECURITY_PROTOCOL is unset, or a supplied Kafka
   security setting is malformed or incomplete. *)
```

`config_of_env` is the standard path for Sol workers and services; the generated
`bin/main.ml` template already calls it. A production-profile deployment sets
`single-broker-loss` for services that declare a Kafka resource in `uses`; the
framework then creates topics with replication factor three and rejects an
existing topic whose Redpanda metadata shows fewer replicas.

## Public API

```ocaml
(** Create a service handle. Starts the underlying producer with linger_ms batching.
    Does not provision topics or register schemas — call register for that. *)
val create
  :  config
  -> sw:Eio.Switch.t
  -> (t, error) result

(** Provision M's topic via the Redpanda admin HTTP API and register its JSON schema
    with the schema registry. Returns a typed topic handle for use with publish and consume.
    Call once per message type at startup. *)
val register
  :  t
  -> net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> (module MESSAGE with type t = 'a)
  -> ('a topic, error) result

(** Encode msg in Confluent wire format and produce it to the broker.
    When trace_ctx is provided it is serialised as a W3C traceparent Kafka message header,
    propagating the trace to consumers. Returns a promise that resolves on broker ack. *)
val publish
  :  t
  -> 'a topic
  -> ?trace_ctx:Obs_trace.t
  -> 'a
  -> (unit, Kafka.Error.t) result Eio.Promise.t

(** Subscribe and process messages. New consumer groups start from the earliest
    retained offset. ack () commits the offset after processing and returns
    the commit's own result — a synchronous librdkafka call that
    can itself fail, distinct from handler failure (see kafka-eio-consumer's
    handler_result/ack docs). trace_ctx in the handler carries the upstream
    traceparent header from the Kafka message — pass it as ?parent:trace_ctx
    to Obs_eio.with_span to link spans. on_ready is called once when the broker
    assigns partitions to this consumer. on_decode_error overrides the default
    decode-error behavior (log + ack + continue); raw_bytes is None when the
    record could not be framed at all. Returns when handler returns Error. *)
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
```

### `?stop` — waking an idle consumer (BUG-067)

Both entry points take `?stop:unit Eio.Promise.t`. The consumer blocks on its
message stream, so without a stop handle nothing can end the loop while the topic
is empty: a worker with nothing to consume, malformed-only traffic, or a stop
requested during the final message would wait for the *next* message. Resolving
the promise ends consumption at the next opportunity instead — `consume` races it
against the blocking take, and `consume_partitioned` feeds its internal stop
signal, which `routing_loop` and the per-partition loops already observe.

A handler that is already running is unaffected: the race happens *between*
messages, so the in-flight handler still completes and acknowledges before
closure. The mechanism lives in the pinned `kafka-eio` package
(`Kafka.Consumer.consume`/`consume_partitioned`, kafka-eio#26); this module and
`sol-worker` pass the handle through.

### `consume_partitioned` — durable retry delivery

`consume_partitioned` routes `Retry` through a group-scoped retry topic and `Dead_letter` to a group-scoped DLQ. The caller supplies a `retry_policy` with at least one attempt. The default decode policy is `Route_to_dlq`: a source record that cannot be decoded is published with its raw payload, key, and headers plus `X-Sol-Decode-Error`; its source offset is acknowledged only after that publish succeeds. `Ack_and_drop` is an explicit opt-in. Decode errors count on `sol_worker_decode_errors_total` when observability is configured. `?consumer_properties` is passed to librdkafka verbatim on both the source and retry consumers, for tuning Sol does not already set.

```ocaml
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
```

### Message ordering

Kafka gives Sol one ordering guarantee, and it is easy to accidentally
expect two more that it doesn't:

- **A. Log order (Kafka provides this).** Records within a single
  partition are delivered to a consumer in exactly the order they were
  appended to that partition's log. There is **no** ordering guarantee
  across partitions — two records with different keys (or the same topic,
  different partitions) have no relative order at all. `kafka-eio`'s
  producer runs with `enable.idempotence = true`
  (`kafka_producer.ml`), which closes the other classic hole: without it,
  producer-side retries can reorder in-flight writes within a partition
  even before a consumer ever sees them.
- **B. Domain order (Kafka does not provide this).** Kafka only orders
  what it received, in the order it received it. If a producer publishes
  domain events `v3, v1, v2, v4` (upstream concurrency, retried publishes,
  multiple producers racing), Kafka faithfully stores and delivers
  `v3, v1, v2, v4` — it has no notion that `v1` was logically supposed to
  precede `v3`. A handler that requires domain-sequential processing
  (e.g. an entity's version history) must enforce or reconcile that
  itself — versioning, idempotency, compare-and-set against stored state —
  Kafka's log order is necessary for this but not sufficient.
- **C. Completion order (retries do not preserve this).** A failed message is republished at a later offset, so it can complete after messages that originally followed it, including same-key messages. See DEC-021's "Ordering consequence" section for the reasoning and use `sol-jobs` for independent jobs that need durable per-message retry.

**The practical rule:** if a handler's correctness depends on strict
processing order (B or C), that's a real constraint to design for
explicitly — partition by the key that must stay ordered and make handlers reconcile domain versions when retries can overtake later records. Independent units of work can use `sol-jobs`.

### Retry topics

On `Retry`, the source record is copied with its raw bytes and key to `<source>.<canonical-group>.retry`, with `X-Sol-Attempt` and `X-Sol-Retry-At` headers. The source offset is acknowledged only after that publish succeeds. The relay re-runs the handler when due. After `retry_policy.max_attempts` failures, or on `Dead_letter`, the record goes to `<source>.<canonical-group>.dlq`; the relay offset is acknowledged only after that publish succeeds. Both destinations are provisioned for the consumer group. The canonical group segment is bounded and includes a hash of the original group ID, so distinct punctuation variants do not collide (BUG-030, BUG-080). The DLQ record also carries `X-Sol-Origin-Group`.

`retry_policy` uses exponential backoff with jitter and a maximum delay; `max_attempts` must be at least 1. Retries are at least once and are not order preserving. A long delay blocks later records in the same retry partition while its queue is full, but a full partition queue pauses fetching from that partition while consumer polling continues, so delays through `retry_policy.max_delay_s` do not cause max-poll eviction; BUG-104 tracks delay tiers. A retry record that cannot be decoded goes to the DLQ with diagnostics before its offset is acknowledged.

Ack/drop behavior follows the [`sol-worker` acknowledgement ownership invariant](../sol-worker/sol-worker.md#acknowledgement-ownership-invariant).

**Relay resilience and exhaustion policy (BUG-029).** The retry consumer's own
publish to the retry/DLQ topic is retried in-process, with backoff
and jitter, before it's treated as a failure at all — a single transient
produce error self-heals rather than reaching `consume_partitioned`'s own
zero-tolerance retry policy for the relay. If those in-process attempts are
exhausted, that **is** treated as a real failure, and the policy is explicit
rather than an accident of internal retry-count configuration: **the relay
failing and never recovering fails the worker**, rather than leaving the
process running with retry delivery silently dead. It fails promptly: when the
relay stops, it closes the source consumer, so `consume_partitioned` (and
`Worker.Make_with_retry(W).run`) returns the relay's `Error` straight away
rather than when the source next stops on its own, which for a healthy idle
source is never (BUG-043). An error the source consumer reports after that close
(for instance an in-flight ack answered with `Destroy`) is a consequence of the
relay failure, so the relay's error is the one returned. `on_relay_publish` distinguishes a publish that ultimately succeeded
from one that was exhausted, separately from `on_retry`, which fires once per
record when a retry is *scheduled* — before publication is even attempted.

### Schema compatibility checking

```ocaml
module Schema : sig
  (** Check whether a MESSAGE schema is compatible with the latest registered version.
      Returns Ok () if compatible or if no version is registered yet (new topic).
      Does not register the schema — safe to call in CI without side effects. *)
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
end
```

Use `Schema.check_all` in `test/test_schemas.ml` (generated by `sol new workspace`) to
gate schema compatibility in CI before breaking changes reach staging. The generated
gate fails (rather than skipping) under CI when `SCHEMA_REGISTRY_URL` is not set, and it
checks only the `MESSAGE` modules listed in it, so list every one.

**Compatibility is FULL, and enforced (BUG-049).** `register` sets the subject's
compatibility to `FULL` *before* registering its schema, and a failure to set it is a
`Schema_registry` error rather than a warning. The registry therefore evaluates every
registration against FULL, and a subject can never silently stay at the registry
default. `check` treats a registry 404 as "no version registered yet" only when its
body carries error code 40401 (subject not found) or 40402 (version not found). Any
other 404, such as a wrong base URL, is an error, not "compatible".

## Wire Format

Every message on the wire uses the Confluent framing:

```
+--------+-------------------+-----------------+
| 0x00   | schema_id (4 B BE)| JSON payload    |
| magic  |                   |                 |
+--------+-------------------+-----------------+
```

This means any Confluent-compatible consumer (other languages, Kafka Streams, etc.)
can decode messages published by Sol services without Sol-specific tooling.

The `Confluent_wire` module exposes the codec for tests:

```ocaml
module Confluent_wire : sig
  val encode : schema_id:int -> Yojson.Safe.t -> bytes
  val decode : bytes -> (int * string, string) result
end
```

## Example: Payments Producer

*The two examples below are illustrative, not compiled in CI — they show the shape
of a caller, and the signatures above are the authority. `MESSAGE` module plumbing
and `Eio_main` setup are elided where they would obscure that shape.*

```ocaml
let () =
  Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
      match Kafka_service.config_of_env () with
      | Error e -> Printf.eprintf "config: %s\n" (Kafka_service.error_to_string e)
      | Ok cfg ->
        (match Kafka_service.create cfg ~sw with
         | Error e -> Printf.eprintf "error: %s\n" (Kafka_service.error_to_string e)
         | Ok svc ->
           (match
              Kafka_service.register svc ~net:env#net ~clock:env#clock (module PaymentEvent)
            with
            | Error e -> Printf.eprintf "error: %s\n" (Kafka_service.error_to_string e)
            | Ok topic ->
              let p =
                Kafka_service.publish
                  svc
                  topic
                  { payment_id = "pay-001"; amount_cents = 9900; currency = "USD" }
              in
              (match Eio.Promise.await p with
               | Ok () -> print_endline "published"
               | Error e -> Printf.eprintf "error: %s\n" (Kafka_service.error_to_string e))))
```

## Example: Audit Consumer

```ocaml
Kafka_service.consume svc topic ~group_id:"audit-svc" ~sw
  ~handler:(fun event ~ack ~trace_ctx:_ ->
    record_audit_log event;
    ignore (ack ());
    Kafka.Consumer.Continue)
  ()
```

Multiple services (`audit-svc`, `financials-svc`) can consume the same `payments`
topic independently using different `group_id` values. Each gets its own offset
cursor — they don't interfere with each other.

## Out of Scope (v1)

- Consumer group lag monitoring
- Batch consume API
- Key encoding (currently keys are not schema-framed)
