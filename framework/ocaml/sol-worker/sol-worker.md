# sol-worker — Worker Primitive

## What it is

`sol-worker` is the Kafka consumer primitive. A `-worker` is a long-running process that subscribes to a topic, processes each message, and emits per-message metrics automatically.

There are two tiers, split at the type level (FEAT-078) rather than by a runtime flag:

- **`WORKER`** (`Make`) — a plain Kafka worker: consume, handle, ack. `handle` returns `ack_outcome`, whose only case is `Ack` — it cannot express `Retry`/`Dead_letter` at all, so there is no retry strategy to configure and none to omit by accident.
- **`RETRYABLE_WORKER`** (`Make_with_retry`) — a worker whose `handle` can return `Ack`, `Retry reason`, or `Dead_letter reason`. Its `run` uses durable retry topics and a bounded default policy with a DLQ; callers may override `~retry_policy`.

Kafka processing is the default worker behavior. `Make_with_retry` provisions a group-scoped retry topic and DLQ. Neither tier requires Postgres — for independent units of work rather than ordered stream processing, see `sol-jobs` (DEC-021/FEAT-077), a library hosted by an ordinary `-worker` binary rather than a Kafka-specific concern of this module.

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
  - `RETRYABLE_WORKER.handle` can additionally return `Retry reason` (route through the retry topic) or `Dead_letter reason` (route straight to the DLQ). `reason` is diagnostic text only — the runtime never inspects it to decide delay, routing, or retryability. Introduce an explicit typed concept if an application needs to influence policy; do not encode conventions into the string.

**Migrating an existing worker that returns `Retry`/`Dead_letter`:** change its module type to `RETRYABLE_WORKER` (usually just annotate `handle`'s return type as `Worker.outcome`, since `Ack` is a shared constructor name between `outcome` and `ack_outcome` and OCaml resolves it from context) and run it with `Make_with_retry` instead of `Make`. This is a breaking change relative to the single-tier `WORKER` FEAT-076 shipped: any worker whose `handle` could return anything but `Ack` must move to the retryable tier.

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
    -> ?retry_policy:retry_policy
    -> ?decode_error_policy:decode_error_policy
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
- `retry_policy` (`Make_with_retry` only, optional) — bounded backoff and attempt budget; see [retry policy](#retry-policy).

`run` owns the full lifecycle: `Kafka_service.create` → `register` → `consume` (`Make`) or `consume_partitioned` (`Make_with_retry`). It returns when `max_messages` is reached, a fatal consumer or relay error occurs, or a shutdown signal is received (SIGTERM, SIGINT, or `stop` resolving).

## Retry policy

`Make_with_retry` uses durable retry topics and a group-scoped DLQ. `default_retry_policy` is `{ base_delay_s = 1.0; max_delay_s = 600.0; max_attempts = 5; jitter_ratio = 0.1 }`. A caller may override it with `~retry_policy`; `max_attempts` must be at least 1. Backoff doubles on each attempt, applies symmetric jitter, and is capped by `max_delay_s`.

On `Retry`, Sol publishes the raw record to the retry topic before acknowledging the source offset. The relay retries it after `X-Sol-Retry-At`; after the final failed attempt, it publishes to the DLQ before acknowledging the retry offset. `Dead_letter` transfers directly to the DLQ. If either publish fails, Sol leaves the record unacknowledged and surfaces the error. Retries are at least once and do not preserve source completion order. The retry relay keeps polling while a partition waits or its queue is full, so delays through `retry_policy.max_delay_s` do not cause max-poll eviction. The retry-topic mechanics and current head-of-line limitation are in `framework/ocaml/kafka-eio-service/kafka-eio-service.md`.

## Lifecycle

```
Make(W).run ~env ~config ?ot ()                              -- Ack-only
Make_with_retry(W).run ~env ~config ?retry_policy ?ot ()    -- retry-capable
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
                Retry _       (RETRYABLE_WORKER only) → metrics error, route to retry topic or DLQ after budget
                Dead_letter _ (RETRYABLE_WORKER only) → metrics dead_letter, route to DLQ
```

After `run` returns:
- If `Kafka_service.create` failed → returns `Error (`Create ...)`
- If `register` failed → returns `Error (`Register ...)`
- On SIGTERM/SIGINT or `stop` resolving → returns normally

Both stop sources are joined into one handle passed to the consumer, so an *idle*
worker — an empty topic, malformed-only traffic, or a stop requested while the
final message is in flight — returns promptly too, rather than waiting for the
next decoded message. `stop_handle`/`join_stop` resolves once, from whichever
source fires first; a handler already running still completes and acknowledges
before the loop ends.

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

`relay_published`/`relay_failed` (BUG-029) are distinct from `retry`: `retry` counts a record for which a retry was *scheduled*, before publication is attempted; `relay_published`/`relay_failed` count whether the retry-topic relay's own publish of that record actually succeeded or was exhausted after in-process backoff retries. A sustained run of `relay_failed` without a matching drop in `retry` is the metric-level signal for the silent-degradation failure BUG-029 fixed — the relay is dying even though messages keep getting scheduled for retry.

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
        ~env ~config ~ot:obs ()
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

A source-topic record that cannot be decoded is covered too (BUG-051, superseding BUG-028's carve-out): under `Make_with_retry` it is dead-lettered by default, acked only once that publish succeeds. Acking it without a transfer is an explicit opt-in — `~decode_error_policy:Ack_and_drop` — or the documented behaviour of an ack-only `Make` worker without a DLQ; never a silent default where a destination exists.

## Error handling

- `W.handle` returning `Retry msg` (`RETRYABLE_WORKER` only) routes to the retry topic, then to the DLQ after the attempt budget; ack/drop behavior follows the [acknowledgement ownership invariant](#acknowledgement-ownership-invariant).
- `W.handle` returning `Dead_letter msg` (`RETRYABLE_WORKER` only) routes the raw message to the group-scoped DLQ topic (BUG-030) acking only once that publish succeeds.
- `W.handle` returning `Ack` but the subsequent ack failing: see [ack semantics](#ack-semantics) above — handled separately from retry, via `ack_failed`.
- Decode errors on the source topic follow `decode_error_policy` (`Make_with_retry`'s `?decode_error_policy`, BUG-051). By default, `Route_to_dlq` publishes the raw record (payload, key, headers) to the group-scoped DLQ with an `X-Sol-Decode-Error` diagnostic and acks only once that publish succeeds; a failed publish leaves it unacked and fails the partition. `Ack_and_drop` (log, count, ack) is the explicit opt-in. `Make` has no DLQ and always acks and drops decode errors. Retry-topic decode errors always go to the DLQ.
- Lifecycle errors (`create`, `register`, Kafka error) are returned as `run_error` values.

## Test injection

`?test_consume_loop` (on `Worker.For_testing.Make`/`Make_with_retry`) bypasses `Kafka_service.create`/`register`/`consume`/`consume_partitioned` entirely, driving the wrapped handler with synthetic messages. Used in unit tests — not intended for production.

```ocaml
let fake_loop ~handler () =
  let _ = handler { id = "test-msg" } ~ack:(fun () -> Ok ()) ~trace_ctx:None in
  ()

Worker.For_testing.Make(W).run ~env ~config ~test_consume_loop:fake_loop ()
```
