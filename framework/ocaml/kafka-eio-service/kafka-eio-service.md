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

  let partitions = 3

  let key t = Some t.payment_id

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

`partitions` and `key` belong to the event's contract, not to the deployment.
`partitions` is what Sol creates the topic with, and it is never reduced:
registering against an existing topic that has **more** partitions is an error
(`Partition_count_reduction`), so every replica of every service agrees on the
count, and consumers can scale up to it. `key` decides the partition, and so the
order a consumer observes — every record sharing a key is handled by one consumer
in publication order, which is what lets per-entity ordering survive more than
one partition. Returning `None` states that the event carries no key: records
spread across partitions and no ordering is claimed for them. The DLQ topic
inherits the source topic's count.

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
   linger_ms = 50)
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

(** Provision M's topic via the Redpanda admin HTTP API and resolve M's schema from the
    registry. Read-only: it never registers a schema version and never changes subject
    configuration. Schema.check verifies the declared schema can read the registered
    versions; Schema.resolve then requires the declared schema to be the registered one.
    A topic whose contract has not been registered fails here, so a producer whose schema
    is not registered fails at startup rather than becoming the first writer. Registration
    belongs to the deployment lifecycle's contract step (Schema.register). Returns a typed
    topic handle for use with publish and consume. Call once per message type at startup. *)
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
    assigns partitions to this consumer. decode_error_policy decides what happens
    to a record the framework could not decode: the default, Route_to_dlq, parks
    it on the consumer group's DLQ and acknowledges its source offset only after
    that publish succeeds, while Ack_and_drop is an explicit opt-in that discards
    it. Returns when handler returns Error. *)
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
```

### `?stop` — waking an idle consumer (BUG-067)

`consume` takes `?stop:unit Eio.Promise.t`. The consumer blocks on its
message stream, so without a stop handle nothing can end the loop while the topic
is empty: a worker with nothing to consume, malformed-only traffic, or a stop
requested during the final message would wait for the *next* message. Resolving
the promise ends consumption at the next opportunity instead — `consume` races it
against the blocking take.

A handler that is already running is unaffected: the race happens *between*
messages, so the in-flight handler still completes and acknowledges before
closure. The mechanism lives in the pinned `kafka-eio` package
(`Kafka.Consumer.consume`, kafka-eio#26); this module and
`sol-worker` pass the handle through.

### DLQ delivery for records the framework cannot decode

A source record that cannot be decoded is published to the consumer group's DLQ as
raw bytes with its original key and headers, plus `X-Sol-Decode-Error` and
`X-Sol-Origin-Group`. Its source offset is acknowledged only after that publish
succeeds, so a DLQ publish failure leaves the record to be redelivered rather than
lost. `Ack_and_drop` replaces this with an ack-and-continue and is an explicit
opt-in, because it discards the record. Decode errors count on
`sol_worker_decode_errors_total` when observability is configured.

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
- **C. Completion order (nothing here preserves it).** A fact a handler declines to apply is not retried in place: the offset stays uncommitted and the consumer stops, so the record completes only when the consumer resumes. See DEC-021's amendment, and use `sol-jobs` for independent work that needs durable retry.

**The practical rule:** if a handler's correctness depends on strict
processing order (B or C), that's a real constraint to design for
explicitly — declare `key` so every record that must stay ordered lands on one
partition, and make handlers reconcile domain versions when redelivery after a
restart can overtake later records. Independent units of work can use `sol-jobs`.

### DLQ naming

The DLQ topic is `<source>.<canonical-group>.dlq`, provisioned for the consumer
group when a consumer starts. The canonical group segment is bounded and includes
a hash of the original group ID, so distinct punctuation variants never share a
DLQ (BUG-030, BUG-080), and the parked record also carries `X-Sol-Origin-Group`.

Ack/drop behaviour follows the [`sol-worker` acknowledgement ownership
invariant](../sol-worker/sol-worker.md#acknowledgement-ownership-invariant).

**There is no message-level retry.** The framework never republishes a
handler-failed record and never advances past one: the handler outcome vocabulary
is exactly `Ack | Fail`, a `Fail` leaves the offset uncommitted, and the consumer
stops so an operator sees the contract failure (DEC-021's amendment). Independent
work that needs durable retry belongs in `sol-jobs`, which retries on its own
lease — not on the stream.

### Contract registration is a deployment step

A runtime process never registers a schema version and never changes subject configuration.
`register` provisions the topic and resolves the declared schema from the registry
(read-only); it fails when the contract has not been registered, so a producer whose schema
is not registered fails at startup instead of becoming the first writer. Registration
belongs to the deployment lifecycle: every workspace exposes a `contract/run` entry point,
which projects each event module's contract metadata as JSON (`--json`) and validates and
registers it against the target registry (`--check` / `--apply`). `MESSAGE.schema` stays
the single source of truth — nothing is duplicated into the manifest. The entry point is
language-neutral: an OCaml workspace's `contract/run` runs the generated
`contract/contract.exe`, a TypeScript workspace's runs its own projection program, and Sol
invokes either the same way (`sh ./contract/run <mode> --scope <scope>`) without knowing
the language underneath.

The reconciliation runs where the registry is reachable, after the destination is
established and before any workload moves, so a deploy that cannot satisfy the contract
fails before rollout:

- `sol up` runs `--apply` locally, because the local target's dependencies are reachable
  from the workstation (and so the workspace's own toolchain must be).
- `sol deploy` runs it inside the destination, because a private registry may only be
  reachable from there. It submits a Job that runs the deployment's own application image
  with `command: ["/usr/local/bin/contract"]` and `args: ["--apply"]`, so the reconciled
  contract cannot drift from the artifact being deployed; every app image builds and
  installs that program. This is the same Job lifecycle the migration gate uses: apply, wait,
  fail closed, capture logs as evidence, clean up on success. One Job per language in the
  deploy's scope is submitted, because two units of the same language share the workspace's
  projection but two languages do not.
- `sol plan` is read-only. It projects the declared contract offline and reports the
  registry as *not observed* when the target registry is private to the destination,
  rather than mutating it or pretending the remote state was seen.

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

  (** The only registry write path: set the subject's compatibility to FULL, then register
      the declared schema. Run by the deployment lifecycle's contract step
      (the generated `contract/contract.exe --apply`); never call it from a running
      workload. *)
  val register
    :  net:_ Eio.Net.t
    -> clock:_ Eio.Time.clock
    -> registry_url:string
    -> (module MESSAGE)
    -> (int, error) result

  (** Read-only: require the declared schema to be the registered one and return its id.
      This is the producer's startup identity check; it never writes. *)
  val resolve
    :  net:_ Eio.Net.t
    -> clock:_ Eio.Time.clock
    -> registry_url:string
    -> (module MESSAGE)
    -> (int, error) result
end

(** The event contract's key semantics: the declared key field read from an encoded
    message. A generated binding supplies the field; the module applies it. *)
module Contract : sig
  val projection : (string * (module MESSAGE)) list -> Yojson.Safe.t

  val key_of_field : string option -> Yojson.Safe.t -> string option
end
```

Use `Schema.check_all` in `test/test_schemas.ml` (generated by `sol new workspace`) to
gate schema compatibility in CI before breaking changes reach staging. The generated
gate fails (rather than skipping) under CI when `SCHEMA_REGISTRY_URL` is not set, and it
checks only the `MESSAGE` modules listed in it, so list every one.

**Compatibility is FULL, and enforced (BUG-049).** `Schema.register` — the contract step,
run by the deployment lifecycle — sets the subject's compatibility to `FULL` *before*
registering its schema, and a failure to set it is a `Schema_registry` error rather than a
warning. The registry therefore evaluates every
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
