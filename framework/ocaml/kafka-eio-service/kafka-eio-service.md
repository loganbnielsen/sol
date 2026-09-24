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
  (* Transport security. Use Kafka.Security.default for local dev.
     In production, set KAFKA_SECURITY_PROTOCOL=sasl_ssl and supply SASL credentials. *)
  }
```

**Preferred: build config from environment variables** using `config_of_env`:

```ocaml
val config_of_env : unit -> (config, error) result
(* Reads:
   KAFKA_BROKERS           — comma-separated broker addresses (default: ["localhost:9092"])
   SCHEMA_REGISTRY_URL     — schema registry HTTP URL (default: "http://localhost:8081")
   REDPANDA_ADMIN_URL      — Redpanda admin API URL   (default: "http://localhost:9644")
   SOL_KAFKA_DURABILITY    — "broker-default" | "single-broker-loss"
   KAFKA_SECURITY_PROTOCOL — "plaintext" | "ssl" | "sasl_plaintext" | "sasl_ssl"
   KAFKA_SSL_CA_LOCATION   — path to CA cert bundle (optional)
   KAFKA_SASL_MECHANISM    — e.g. "SCRAM-SHA-256" (optional)
   KAFKA_SASL_USERNAME / KAFKA_SASL_PASSWORD — SASL credentials (optional)
   linger_ms = 50, partitions = 1)
(* Returns Error when a supplied Kafka security setting is malformed or
   incomplete. *)
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
```

### `consume_partitioned` — per-partition fiber isolation

```ocaml
(** Like consume but routes each message to a dedicated per-partition fiber.
    A partition's in-memory retry sleep pauses that Kafka partition for the retry
    delay; other partitions continue unaffected. During the sleep the partition is
    paused at the librdkafka level so no messages accumulate in its stream buffer. *)
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
- **C. Completion order (`Retry_topics` deliberately does not preserve
  this).** Even when Kafka delivers `1, 2, 3, 4` in order, a failed
  message on `Retry_topics` is republished at a later offset rather than
  blocking its partition, so it can complete *after* messages that
  originally followed it — including same-key messages. `In_memory`
  instead blocks its partition for the retry sleep, preserving completion
  order at the cost of pausing later messages on that partition. See
  DEC-021's "Ordering consequence" section for the full reasoning and the
  `sol-jobs` (FEAT-077) escape hatch for workloads that need independent
  per-message retry regardless of key.

**The practical rule:** if a handler's correctness depends on strict
processing order (B or C), that's a real constraint to design for
explicitly — partition by the key that must stay ordered, and choose
`In_memory` (or a leased-job primitive once one exists) over
`Retry_topics`. If the events a handler processes are genuinely
independent of each other, don't manufacture an ordering requirement Kafka
never promised in the first place.

### Retry strategy

```ocaml
type retry_strategy =
  | In_memory of Kafka.Consumer.retry_policy
    (* Exponential back-off sleep inside the partition fiber (delay =
       base_delay_s * 2^(attempt-1), jittered by jitter_ratio, clamped to
       max_delay_s). Simple, zero infra. Pauses that Kafka partition for the
       retry delay. Vulnerable to rebalance preempting the sleep window. On
       exhaustion, or on Dead_letter (In_memory has no DLQ to route it to):
       terminal handler failure -- the message is left unacknowledged
       (FEAT-078). *)
  | Retry_topics of Kafka.Consumer.retry_policy
    (* Both variants share this one retry_policy vocabulary (FEAT-078) but
       are not feature-equivalent -- exhaustion disposition below is
       strategy-specific by design.
       On Retry: publish raw bytes (with the original message's key -- BUG-027,
       so a retried message hashes to the same partition on the retry topic
       that it would on the source topic, both sharing the same partition
       count) to <source>.<canonical-group>.retry with X-Sol-Attempt /
       X-Sol-Retry-At headers; commit original offset immediately. The retry
       delay is retry_policy.base_delay_s * 2^(attempt-1), jittered by
       retry_policy.jitter_ratio and clamped to retry_policy.max_delay_s --
       the same computation In_memory uses (Kafka.Consumer.backoff_s), not
       just the same type.
       Retry and DLQ topic names are group-scoped (BUG-030): both are
       <source>.<canonical-group>.<retry|dlq>, where <canonical-group> is
       group_id sanitized to alphanumerics and '-' (Kafka's metrics/JMX
       naming treats '.' and '_' as interchangeable, so unsanitized ids risk
       metric-name collisions) and, if long enough to risk Kafka's 249-byte
       topic name limit, truncated with a content-hash suffix. Retry and DLQ
       destinations belong to the logical consumer group whose processing
       responsibility they receive -- dead-lettering is a statement about
       that group's processing attempt, not an intrinsic property of the
       source event, so two independent groups consuming the same source
       topic get fully isolated retry/DLQ topics rather than racing on a
       shared <topic>-retry/<topic>-dlq pair (DEC-021). Every DLQ record
       still carries an X-Sol-Origin-Group header naming the group that
       dead-lettered it, as provenance -- not needed for routing, since the
       topic name already encodes it.
       A background retry consumer (group <group_id>-sol-retry), itself routed
       through consume_partitioned, delays until X-Sol-Retry-At then re-runs
       the handler. That sleep blocks the retry partition, not the whole retry
       topic; every later record assigned to that retry partition waits behind
       it, including unrelated keys that hashed to the same partition.
       Republish also gives the retry a later Kafka offset, so it can execute
       after records that originally followed it on the source partition,
       including records with the same key.
       In steady state the extra head-of-line delay is bounded roughly by
       retry_policy.max_delay_s; under backlog or overload Kafka is the
       buffer, so observed delay is unbounded. After retry_policy.max_attempts
       failures, or on Dead_letter, the message is routed to the DLQ topic
       and the retry offset acked only once that publish succeeds. Both
       topics are auto-provisioned. retry_policy.max_attempts must be at
       least 1.
       If a retry record cannot be decoded, the retry path does not call
       on_decode_error; it publishes the raw retry record and original headers
       to the DLQ topic with decode diagnostics, then acks only after that
       publish succeeds (BUG-028).
       Ack/drop behavior follows sol-worker.md's acknowledgement ownership
       invariant. Retry_topics does not preserve strict source-partition or
       per-key ordering; workloads that need independent per-message retry
       regardless of key need a leased-job primitive (DEC-021). *)
```

There is no `default_retry_strategy` (removed, FEAT-078): `retry_strategy` is a
mandatory argument to `consume_partitioned`, never an implicit fallback. A
missing retry strategy must never be discovered only after a message first
fails to process -- see `sol-worker.md`'s `WORKER`/`RETRYABLE_WORKER` split,
which enforces this at the type level one layer up.

Ack/drop behavior follows the
[`sol-worker` acknowledgement ownership invariant](../sol-worker/sol-worker.md#acknowledgement-ownership-invariant).

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
