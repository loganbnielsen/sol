# sol-worker — Worker Primitive

## What it is

`sol-worker` is the Kafka consumer primitive. A `-worker` is a long-running process that subscribes to a topic, processes each message, and emits per-message metrics automatically.

There are two tiers, split at the type level (FEAT-078) rather than by a runtime flag:

- **`WORKER`** (`Make`) — a plain Kafka worker: consume, handle, ack. `handle` returns `ack_outcome`, whose only case is `Ack` — it cannot express `Retry`/`Dead_letter` at all, so there is no retry strategy to configure and none to omit by accident.
- **`RETRYABLE_WORKER`** (`Make_with_retry`) — a worker whose `handle` can return `Ack`, `Retry reason`, or `Dead_letter reason`. Its `run` *requires* `~retry_strategy` — there is no implicit default. A missing retry strategy is a compile error here, never a runtime surprise discovered the first time a message fails.

Kafka processing is the default worker behavior; when durable asynchronous retry is explicitly enabled, `Retry_topics` is the recommended production implementation. Neither tier requires Postgres or an implicit retry mechanism — for independent units of work rather than ordered stream processing, see `sol-jobs` (DEC-021/FEAT-077), a library hosted by an ordinary `-worker` binary rather than a Kafka-specific concern of this module.

## Module types

```ocaml
type ack_outcome = Ack

module type WORKER = sig
  module Message : Kafka_service.MESSAGE
  val group_id : string
  val handle : Message.t -> trace_ctx:Obs_trace.t option -> ack_outcome
end

type outcome =
  | Ack
  | Retry of string
  | Dead_letter of string

module type RETRYABLE_WORKER = sig
  module Message : Kafka_service.MESSAGE
  val group_id : string
  val handle : Message.t -> trace_ctx:Obs_trace.t option -> outcome
end
```

- `Message` — the event contract. Defines topic name, JSON schema, encode/decode.
- `group_id` — Kafka consumer group ID. Must be stable across restarts.
- `handle` — called once per decoded message. `trace_ctx` carries the upstream W3C `traceparent` header from the Kafka message — pass it as `?parent:trace_ctx` to `Obs_eio.with_span` to link spans. There is no `ack` to call — see [ack semantics](#ack-semantics).
  - `WORKER.handle` can only return `Ack`.
  - `RETRYABLE_WORKER.handle` can additionally return `Retry reason` (route through the configured retry strategy) or `Dead_letter reason` (route straight to the DLQ when `Retry_topics` is configured; fails closed under `In_memory`, which has no DLQ — see [error handling](#error-handling)). `reason` is diagnostic text only — the runtime never inspects it to decide delay, routing, or retryability. Introduce an explicit typed concept if an application needs to influence policy; do not encode conventions into the string.

**Migrating an existing worker that returns `Retry`/`Dead_letter`:** change its module type to `RETRYABLE_WORKER` (usually just annotate `handle`'s return type as `Worker.outcome`, since `Ack` is a shared constructor name between `outcome` and `ack_outcome` and OCaml resolves it from context) and run it with `Make_with_retry` instead of `Make`, passing an explicit `~retry_strategy`. This is a breaking change relative to the single-tier `WORKER` FEAT-076 shipped: any worker whose `handle` could return anything but `Ack` must move to the retryable tier.

## Entrypoints

```ocaml
module Make (W : WORKER) : sig
  val run
    :  env:< net       : _ Eio.Net.t
           ; clock     : _ Eio.Time.clock
           ; mono_clock: _ Eio.Time.Mono.t
           ; .. >
    -> config:Kafka_service.config
    -> ?ot:Sol_obs.t
    -> ?metrics_port:int
    -> ?on_ready:(unit -> unit)
    -> ?stop:unit Eio.Promise.t
    -> ?max_messages:int
    -> unit
    -> (unit, run_error) result
end

module Make_with_retry (W : RETRYABLE_WORKER) : sig
  val run
    :  env:(same as above)
    -> config:Kafka_service.config
    -> retry_strategy:retry_strategy
    -> ?ot:Sol_obs.t
    -> ?metrics_port:int
    -> ?on_ready:(unit -> unit)
    -> ?stop:unit Eio.Promise.t
    -> ?max_messages:int
    -> unit
    -> (unit, run_error) result
end
```

- `ot` — when provided, emits `sol_worker_messages_total{status}` and `sol_worker_message_duration_seconds` per message, and exposes `GET /metrics` on `metrics_port` for Prometheus scraping.
- `metrics_port` — default `9090`. Only binds when `ot` is provided; pass `0` for an OS-assigned port when running more than one `-worker`/`-svc` in the same process.
- `on_ready` — called exactly once when the broker assigns partitions to this consumer.
- `stop` — external stop signal. Resolve to request graceful shutdown; checked alongside the worker's own SIGTERM/SIGINT handling, not in place of it.
- `max_messages` — stop cleanly after this many successfully processed messages. Useful in tests.
- `retry_strategy` (`Make_with_retry` only, mandatory) — how to handle `Retry`/`Dead_letter` results from `W.handle`. See [retry strategy](#retry-strategy).

`run` owns the full lifecycle: `Kafka_service.create` → `register` → `consume` (`Make`) or `consume_partitioned` (`Make_with_retry`). It returns when `max_messages` is reached, the retry budget is exhausted (`Make_with_retry` only), or a shutdown signal is received (SIGTERM, SIGINT, or `stop` resolving).

## Retry strategy

```ocaml
type retry_policy = {
  base_delay_s : float;   (* Initial backoff in seconds. Doubles on each consecutive failure. *)
  max_delay_s  : float;   (* Backoff cap, even after jitter. Default: 600.0 (10 minutes). *)
  max_attempts : int;     (* Maximum handler invocations, including the initial one.
                              Negative = retry indefinitely. 1 = no retry. Default: -1. *)
  jitter_ratio : float;   (* Symmetric jitter as a fraction of the raw delay, applied before
                              the max_delay_s clamp (e.g. 0.1 = +-10%). 0.0 disables jitter.
                              Default: 0.1. *)
}

type retry_strategy =
  | In_memory    of retry_policy
    (* Exponential back-off sleep inside the partition fiber (delay = base_delay_s *
       2^(attempt-1), jittered, clamped to max_delay_s). Simple, zero infra. Pauses that
       Kafka partition for the retry delay; vulnerable to rebalance preempting the sleep
       window. On exhaustion, or on Dead_letter (In_memory has no DLQ to route it to):
       terminal handler failure -- the message is left unacknowledged and the
       partition/worker fails under normal consumer semantics. No DLQ promise; this is
       the simple/dev option, not the production one. *)
  | Retry_topics of retry_policy
    (* On Retry: publish raw bytes to the group-scoped retry topic
       (<source>.<canonical-group>.retry, BUG-030); commit original offset immediately. A
       background retry consumer delays until X-Sol-Retry-At then re-runs W.handle. After
       retry.max_attempts failures, or on Dead_letter, the message is moved to the
       group-scoped DLQ topic (<source>.<canonical-group>.dlq), and the retry offset is
       acked only once that publish succeeds. Production Kafka-native option: durable
       retry + DLQ. *)
```

Both variants share this one `retry_policy` vocabulary but are **not feature-equivalent** — exhaustion disposition is strategy-specific by design, not an oversight. `max_attempts` controls when Sol stops retrying; it does not promise a terminal DLQ on every strategy.

There is no `default_retry_strategy` and no default for `~retry_strategy` on `Make_with_retry(W).run` — every retry-capable worker must name its strategy explicitly (FEAT-078). Pick `In_memory Kafka.Consumer.default_retry` for the simple/dev behavior a pre-FEAT-078 worker got implicitly, or `Retry_topics` for durable retry + DLQ.

**Backoff-schedule change (user-visible, FEAT-078):** `Retry_topics`'s delay used to be a hardcoded, unjittered `min(1.0 * 2^n, 600.0)` (first retry at 2s, capped at 600s). It is now `base_delay_s * 2^(attempt-1)` from the caller-supplied `retry_policy`, jittered by `jitter_ratio` and clamped to `max_delay_s`. A `Retry_topics { base_delay_s = 1.0; max_delay_s = 600.0; jitter_ratio = 0.0; ... }` reproduces the old schedule exactly (modulo the `n` vs. `attempt-1` off-by-one, which the old schedule's first retry at `2^1=2s` already matches).

`Retry_topics` is at-least-once, not order-preserving. The retry-topic mechanics
are documented in `framework/ocaml/kafka-eio-service/kafka-eio-service.md`: a retry
delay blocks every later record sharing that retry partition, not just the same
key; republishing assigns a later Kafka offset, so a retry can run after records
that originally followed it; and the steady-state head-of-line bound disappears
under backlog or overload.

## Lifecycle

```
Make(W).run ~env ~config ?ot ()                              -- Ack-only
Make_with_retry(W).run ~env ~config ~retry_strategy ?ot ()    -- retry-capable
  │
  ├─ Register metrics if ot provided
  │    sol_worker_messages_total{status}        [counter]
  │    sol_worker_message_duration_seconds      [histogram]
  │
  └─ Switch.run (outer)
       ├─ fork_daemon: signal handler → stop requested  (self-pipe)
       │
       └─ Kafka_service.create → register → consume / consume_partitioned
            per message:
              if stop requested or max_messages reached → Stop  (graceful drain)
              else W.handle msg ~trace_ctx
                Ack                                → ack() (the framework's, not W.handle's)
                                                        Ok ()                  → metrics ok, Continue/Stop
                                                        Error e, is_fatal e    → metrics ack_failed, Error e (Stop + raise)
                                                        Error e, not fatal     → metrics ack_failed, Continue
                Retry _       (RETRYABLE_WORKER only) → metrics error, retry per strategy; after budget exhausted → Stop + raise
                Dead_letter _ (RETRYABLE_WORKER only) → metrics dead_letter, route to DLQ if Retry_topics, else fail closed
```

After `run` returns:
- If the retry budget was exhausted (`Make_with_retry` only) → returns `Error (`Consume ...)`
- If `Kafka_service.create` failed → returns `Error (`Create ...)`
- If `register` failed → returns `Error (`Register ...)`
- On SIGTERM/SIGINT or `stop` resolving → returns normally

## Signal handling

Self-pipe trick (same pattern as `sol-svc` and `sol-fn`), implemented once in `Sol_runtime` and shared by every service primitive:
1. `Unix.pipe ~cloexec:true` + `Unix.set_nonblock w`
2. `SIGTERM`/`SIGINT` handler: `Unix.single_write w "\x00"` (async-signal-safe)
3. `Fiber.fork_daemon ~sw`: `Eio_unix.await_readable r` → resolve the stop promise

The stop condition is checked at the top of the message handler, so the consumer finishes the current message before stopping (graceful drain) rather than aborting mid-message.

## Metrics

When `?ot` is provided:

| Metric | Type | Labels | Description |
|---|---|---|---|
| `sol_worker_messages_total` | counter | `status` | Messages processed. `Make` (Ack-only) can only ever emit `ok`/`ack_failed` — it structurally cannot produce `retry`/`error`/`dead_letter`/`relay_published`/`relay_failed`, since `handle` cannot return anything but `Ack`. `Make_with_retry` can emit all of: `ok`, `retry`, `error`, `dead_letter`, `ack_failed`, `relay_published`, `relay_failed`. |
| `sol_worker_message_duration_seconds` | histogram | — | Per-message processing latency |

`ack_failed` is distinct from `error`: `W.handle` returned `Ack` (the side effect happened) but the offset commit itself failed. See [ack semantics](#ack-semantics).

`relay_published`/`relay_failed` (`Retry_topics` only, BUG-029) are distinct from `retry`: `retry` counts a record for which a retry was *scheduled*, before publication is attempted; `relay_published`/`relay_failed` count whether the retry-topic relay's own publish of that record actually succeeded or was exhausted after in-process backoff retries. A sustained run of `relay_failed` without a matching drop in `retry` is the metric-level signal for the silent-degradation failure BUG-029 fixed — the relay is dying even though messages keep getting scheduled for retry.

Metrics are registered once at startup. Emitter functions are called in the handler closure on each message.

## Usage examples

Ack-only:

```ocaml
module PingWorker = struct
  module Message = Events.System.Ping

  let group_id = "ops-ping-worker"

  let handle msg ~trace_ctx:_ =
    Printf.printf "ping: %s\n%!" msg.Events.System.Ping.id;
    Worker.Ack
end

let () =
  Eio_main.run @@ fun env ->
    match Kafka_service.config_of_env () with
    | Error e -> failwith (Kafka_service.error_to_string e)
    | Ok config ->
      Worker.Make(PingWorker).run ~env ~config ()
      |> Result.map_error Worker.run_error_to_string
      |> function Ok () -> () | Error msg -> failwith msg
```

Retry-capable:

```ocaml
module BroadcastWorker = struct
  module Message = Events.Payments.Charged

  let group_id = "comms-broadcast-worker"

  let handle msg ~trace_ctx:_ : Worker.outcome =
    match Comms.send_push_notification msg with
    | Ok ()   -> Worker.Ack
    | Error e -> Worker.Retry e
end

let () =
  Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let obs = Sol_obs.of_env ~sw ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
                ~service:BroadcastWorker.group_id () in
    match Kafka_service.config_of_env () with
    | Error e -> failwith (Kafka_service.error_to_string e)
    | Ok config ->
      Worker.Make_with_retry(BroadcastWorker).run
        ~env ~config ~retry_strategy:(Worker.In_memory Kafka.Consumer.default_retry) ~ot:obs ()
      |> Result.map_error Worker.run_error_to_string
      |> function Ok () -> () | Error msg -> failwith msg
```

## ack semantics

`W.handle` does not receive (or call) an `ack`. `run` commits the Kafka offset itself, and only after `W.handle` returns `Ack` — never before, and never on `Retry`. This removes an entire class of app-level bugs: forgetting to ack, acking in the wrong branch, or acking before a side effect that can still fail. For at-least-once semantics this is the correct default; at-exactly-once is not supported in v1.

A failed commit is **not** treated like a handler failure. The side effect in `W.handle` already succeeded, so retrying it (as a `Retry` from `W.handle` would) risks duplicating it. Instead:

- The commit failure is logged (`Warn`, or `Error` if fatal) and counted as `sol_worker_messages_total{status="ack_failed"}`.
- If `Kafka_error.is_fatal e` — a broken consumer, not a transient hiccup — it escalates to an `Error`, stopping the worker the same way an exhausted retry budget would.
- Otherwise, the worker continues. The offset was never committed, so the message remains eligible for natural redelivery — no immediate duplicate side effect, no lost message.

### Acknowledgement ownership invariant

> **Sol must not acknowledge failed work unless responsibility for that work has durably transferred to another valid destination.**
>
> This applies uniformly to retry, dead-letter, decode-failure, and retry-exhaustion paths. If the required durable transfer fails or no valid destination exists, the message remains unacknowledged and the failure is surfaced.
>
> Valid transfer includes successfully publishing a retry record to the retry topic or a terminal record to the DLQ. Logging an error, exhausting retries, or deciding not to process a message does not itself constitute durable transfer.

"Failed work" is the deliberate scope: a source-topic decode error may still skip-and-ack a message that was never accepted, and that is not a violation.

## Error handling

- `W.handle` returning `Retry msg` (`RETRYABLE_WORKER` only) triggers the retry strategy. After the retry budget is exhausted, `run` returns `Error`; ack/drop behavior follows the [acknowledgement ownership invariant](#acknowledgement-ownership-invariant).
- `W.handle` returning `Dead_letter msg` (`RETRYABLE_WORKER` only) routes the raw message to the group-scoped DLQ topic (BUG-030) when `Retry_topics` is configured, acking only once that publish succeeds. Under `In_memory` (no DLQ exists to route to), it **fails closed** (FEAT-078): the message is left unacknowledged and treated as a terminal failure, exactly like an exhausted retry — never acknowledged-and-discarded, per the [acknowledgement ownership invariant](#acknowledgement-ownership-invariant).
- `W.handle` returning `Ack` but the subsequent ack failing: see [ack semantics](#ack-semantics) above — handled separately from retry, via `ack_failed`.
- Decode errors on the source topic: default behavior from `Kafka_service.consume`/`consume_partitioned` logs to stderr, acks the message, and continues. Override via `on_decode_error` by calling `Kafka_service.consume`/`consume_partitioned` directly. Source-topic skip-and-ack is permitted by the invariant above because the message was never accepted. Retry-topic decode errors are different: `Retry_topics` publishes the raw retry record to the DLQ with decode diagnostics and only then acks it.
- Lifecycle errors (`create`, `register`, Kafka error) are returned as `run_error` values.

## Test injection

`?test_consume_loop` (on `Worker.For_testing.Make`/`Make_with_retry`) bypasses `Kafka_service.create`/`register`/`consume`/`consume_partitioned` entirely, driving the wrapped handler with synthetic messages. Used in unit tests — not intended for production.

```ocaml
let fake_loop ~handler () =
  let _ = handler { id = "test-msg" } ~ack:(fun () -> Ok ()) ~trace_ctx:None in
  ()

Worker.For_testing.Make(W).run ~env ~config ~test_consume_loop:fake_loop ()
```
