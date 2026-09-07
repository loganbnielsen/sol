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
type config = {
  brokers             : string list;
  schema_registry_url : string;       (* "http://localhost:8081" *)
  admin_url           : string;       (* Redpanda admin API, e.g. "http://localhost:9644" *)
  linger_ms           : int;          (* batch window; 50ms recommended *)
  partitions          : int;          (* partition count for auto-provisioned topics *)
  security            : Kafka_security.t;
  (* Transport security. Use Kafka_security.default for local dev.
     In production, set KAFKA_SECURITY_PROTOCOL=sasl_ssl and supply SASL credentials. *)
}
```

**Preferred: build config from environment variables** using `config_of_env`:

```ocaml
val config_of_env : unit -> config
(* Reads:
   KAFKA_BROKERS           — comma-separated broker addresses (default: ["localhost:9092"])
   SCHEMA_REGISTRY_URL     — schema registry HTTP URL (default: "http://localhost:8081")
   REDPANDA_ADMIN_URL      — Redpanda admin API URL   (default: "http://localhost:9644")
   KAFKA_SECURITY_PROTOCOL — "plaintext" | "ssl" | "sasl_plaintext" | "sasl_ssl"
   KAFKA_SSL_CA_LOCATION   — path to CA cert bundle (optional)
   KAFKA_SASL_MECHANISM    — e.g. "SCRAM-SHA-256" (optional)
   KAFKA_SASL_USERNAME / KAFKA_SASL_PASSWORD — SASL credentials (optional)
   linger_ms = 50, partitions = 1 *)
```

`config_of_env` is the standard path for Sol workers and services; the generated
`bin/main.ml` template already calls it.

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
  -> (unit, Kafka_error.t) result Eio.Promise.t

(** Subscribe and process messages. New consumer groups start from the earliest
    retained offset. ack () commits the offset after processing and returns
    the commit's own result — a synchronous librdkafka call that
    can itself fail, distinct from handler failure (see kafka-eio-consumer's
    handler_result/ack docs). trace_ctx in the handler carries the upstream
    traceparent header from the Kafka message — pass it as ?parent:trace_ctx
    to Obs_eio.with_span to link spans. on_ready is called once when the broker
    assigns partitions to this consumer. on_decode_error overrides the default
    decode-error behavior (log + ack + continue). Returns when handler returns
    Error. *)
val consume
  :  t
  -> 'a topic
  -> group_id:string
  -> sw:Eio.Switch.t
  -> ?on_ready:(unit -> unit)
  -> ?on_decode_error:(string -> raw_bytes:bytes -> ack:(unit -> (unit, Kafka_error.t) result) -> Kafka_error.t Kafka_consumer.handler_result)
  -> ?ot:Obs_eio.t
  -> handler:('a -> ack:(unit -> (unit, Kafka_error.t) result) -> trace_ctx:Obs_trace.t option -> Kafka_error.t Kafka_consumer.handler_result)
  -> unit
  -> (unit, Kafka_error.t) result
```

### `consume_partitioned` — per-partition fiber isolation

```ocaml
(** Like consume but routes each message to a dedicated per-partition fiber.
    A partition's in-memory retry sleep blocks only that partition; other partitions
    continue unaffected. During the sleep the partition is paused at the librdkafka
    level so no messages accumulate in its stream buffer. *)
val consume_partitioned
  :  t
  -> 'a topic
  -> group_id:string
  -> sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> ?on_ready:(unit -> unit)
  -> ?on_decode_error:(string -> raw_bytes:bytes -> ack:(unit -> (unit, Kafka_error.t) result) -> Kafka_error.t Kafka_consumer.handler_result)
  -> ?retry_strategy:retry_strategy
  -> ?on_retry:(partition:int32 -> attempt:int -> delay_s:float -> unit)
  -> ?ot:Obs_eio.t
  -> handler:('a -> ack:(unit -> (unit, Kafka_error.t) result) -> trace_ctx:Obs_trace.t option -> Kafka_error.t Kafka_consumer.handler_result)
  -> unit
  -> (unit, Kafka_error.t) result
```

### Retry strategy

```ocaml
type retry_strategy =
  | In_memory    of Kafka_consumer.retry_policy
    (* Exponential back-off sleep inside the partition fiber. Simple, zero infra.
       Vulnerable to rebalance preempting the sleep window. *)
  | Retry_topics of { max_attempts : int }
    (* On failure: publish raw bytes to <topic>-retry with X-Sol-Attempt /
       X-Sol-Retry-At headers; commit original offset immediately.
       A background retry consumer (group <group_id>-sol-retry) delays until
       X-Sol-Retry-At then re-runs the handler. After max_attempts failures
       the message is routed to <topic>-dlq. Both topics are auto-provisioned. *)

val default_retry_strategy : retry_strategy
(* In_memory with exponential backoff starting at 1s, capped at 10min, infinite retries. *)
```

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
gate schema compatibility in CI before breaking changes reach staging.

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

```ocaml
let () =
  Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
      let cfg = Kafka_service.config_of_env () in
      match Kafka_service.create cfg ~sw with
      | Error e -> failwith e
      | Ok svc ->
        match Kafka_service.register svc ~net:env#net ~clock:env#clock (module PaymentEvent) with
        | Error e -> failwith e
        | Ok topic ->
          let p = Kafka_service.publish svc topic
            { payment_id = "pay-001"; amount_cents = 9900; currency = "USD" }
          in
          match Eio.Promise.await p with
          | Ok ()   -> print_endline "published"
          | Error e -> Printf.eprintf "error: %s\n" (Kafka_error.to_string e)
```

## Example: Audit Consumer

```ocaml
Kafka_service.consume svc topic ~group_id:"audit-svc" ~sw
  ~handler:(fun event ~ack ~trace_ctx:_ ->
    record_audit_log event;
    ignore (ack ());
    Kafka_consumer.Continue
  ) ()
```

Multiple services (`audit-svc`, `financials-svc`) can consume the same `payments`
topic independently using different `group_id` values. Each gets its own offset
cursor — they don't interfere with each other.

## Out of Scope (v1)

- Schema evolution / compatibility enforcement (add `compatibility` setting to schema registry)
- Consumer group lag monitoring
- Batch consume API
- Key encoding (currently keys are not schema-framed)
