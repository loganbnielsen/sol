# sol-worker — Worker Primitive

## What it is

`sol-worker` is the Kafka consumer primitive. A `-worker` is a long-running process that subscribes to a topic, processes each message, and emits per-message metrics automatically.

The abstraction is the handler — `handle : Message.t -> trace_ctx:Obs_trace.t option -> (unit, string) result`. Sol handles the consumer lifecycle, schema registration, acknowledgement, graceful shutdown, and observability wiring.

## Module type

```ocaml
module type WORKER = sig
  module Message : Kafka_service.MESSAGE
  val group_id : string
  val handle : Message.t -> trace_ctx:Obs_trace.t option -> (unit, string) result
end
```

- `Message` — the event contract. Defines topic name, JSON schema, encode/decode.
- `group_id` — Kafka consumer group ID. Must be stable across restarts.
- `handle` — called once per decoded message. `trace_ctx` carries the upstream W3C `traceparent` header from the Kafka message — pass it as `?parent:trace_ctx` to `Obs_eio.with_span` to link spans. Return `Ok ()` to continue, `Error msg` to retry (see retry strategy). There is no `ack` to call — see [ack semantics](#ack-semantics).

## Entrypoint

```ocaml
module Make (W : WORKER) : sig
  val run
    :  env:< net       : _ Eio.Net.t
           ; clock     : _ Eio.Time.clock
           ; mono_clock: _ Eio.Time.Mono.t
           ; .. >
    -> config:Kafka_service.config
    -> ?ot:Sol_obs.t
    (** When provided, emits sol_worker_messages_total{status} and
        sol_worker_message_duration_seconds per message, and exposes
        GET /metrics on metrics_port for Prometheus scraping. *)
    -> ?metrics_port:int
    (** Default: 9090. Only binds when ot is provided; pass 0 for an
        OS-assigned port when running more than one -worker/-svc in the
        same process. *)
    -> ?on_ready:(unit -> unit)
    (** Called exactly once when the broker assigns partitions to this consumer.
        Use it to signal readiness to a test or health-check. *)
    -> ?stop:bool Atomic.t
    (** External stop flag. Set to true for graceful shutdown from outside the worker. *)
    -> ?max_messages:int
    (** Stop cleanly after this many successfully processed messages. Useful in tests. *)
    -> ?retry_strategy:retry_strategy
    (** How to handle Error results from W.handle. Defaults to In_memory default_retry. *)
    -> ?_consume_loop:
         (handler:(W.Message.t -> ack:(unit -> (unit, Kafka_error.t) result) -> trace_ctx:Obs_trace.t option -> Kafka_error.t Kafka_consumer.handler_result)
          -> unit -> unit)
    (** Test injection: replace the real per-partition consume loop with a stub. *)
    -> unit
    -> unit
end
```

`Make(W).run` owns the full lifecycle: `Kafka_service.create` → `register` → `consume_partitioned`. It returns when the stop flag is set, `max_messages` is reached, `W.handle` fails beyond the retry budget, or a shutdown signal is received (SIGTERM or SIGINT).

## Retry strategy

```ocaml
type retry_policy = {
  base_delay_s : float;   (* Initial backoff in seconds. Doubles on each consecutive failure. *)
  max_delay_s  : float;   (* Backoff cap. Default: 600.0 (10 minutes). *)
  max_attempts : int;     (* Negative = retry indefinitely. Default: -1. *)
}

val default_retry : retry_policy
(* base_delay_s = 1.0, max_delay_s = 600.0, max_attempts = -1 *)

type retry_strategy =
  | In_memory    of retry_policy
    (* Exponential back-off sleep inside the partition fiber. Simple, zero infra.
       Vulnerable to rebalance preempting the sleep window. *)
  | Retry_topics of { max_attempts : int }
    (* On failure: publish raw bytes to <topic>-retry; commit original offset immediately.
       A background retry consumer delays until X-Sol-Retry-At then re-runs W.handle.
       After max_attempts failures the message is moved to <topic>-dlq. *)

val default_retry_strategy : retry_strategy
(* In_memory default_retry — in-process exponential backoff, infinite retries. *)
```

Pass `~retry_strategy` to `Make(W).run` to choose the failure-handling mode.

## Lifecycle

```
Make(W).run ~env ~config ?ot ?retry_strategy ()
  │
  ├─ Register metrics if ot provided
  │    sol_worker_messages_total{status}        [counter]
  │    sol_worker_message_duration_seconds      [histogram]
  │
  ├─ Atomic stop_flag = false
  │
  └─ Switch.run (outer)
       ├─ fork_daemon: signal handler → stop_flag := true  (self-pipe)
       │
       └─ Kafka_service.create → register → consume_partitioned
            per-partition fiber per message:
              if stop_flag → Stop         (graceful drain)
              else W.handle msg ~trace_ctx
                Error _ → metrics error, retry per strategy; after budget exhausted → Stop + raise
                Ok ()   → ack () (the framework's, not W.handle's)
                            Ok ()                    → metrics ok, Continue
                            Error e, is_fatal e       → metrics ack_failed, Error e (Stop + raise)
                            Error e, not is_fatal e   → metrics ack_failed, Continue
```

After `run` returns:
- If `W.handle` exhausted its retry budget → returns `Error (`Consume ...)`
- If `Kafka_service.create` failed → returns `Error (`Create ...)`
- If `register` failed → returns `Error (`Register ...)`
- On SIGTERM/SIGINT or `stop` flag → returns normally

## Signal handling

Self-pipe trick (same pattern as `sol-svc` and `sol-fn`):
1. `Unix.pipe ~cloexec:true` + `Unix.set_nonblock w`
2. `SIGTERM`/`SIGINT` handler: `Unix.single_write w "\x00"` (async-signal-safe)
3. `Fiber.fork_daemon ~sw`: `Eio_unix.await_readable r` → set `stop_flag := true`

Using `Atomic.t` rather than a promise: the stop flag is checked in the message handler, so the consumer finishes the current message before stopping (graceful drain). A promise + cancellation would abort mid-message.

## Metrics

When `?ot` is provided:

| Metric | Type | Labels | Description |
|---|---|---|---|
| `sol_worker_messages_total` | counter | `status` | Messages processed (`ok`, `retry`, `error`, or `ack_failed`) |
| `sol_worker_message_duration_seconds` | histogram | — | Per-message processing latency |

`ack_failed` is distinct from `error`: `W.handle` returned `Ok ()` (the side effect happened) but the offset commit itself failed. See [ack semantics](#ack-semantics).

Metrics are registered once at startup. Emitter functions are called in the handler closure on each message.

## Usage example

```ocaml
module BroadcastWorker = struct
  module Message = Events.Payments.Charged

  let group_id = "comms-broadcast-worker"

  let handle msg ~trace_ctx:_ =
    match Comms.send_push_notification msg with
    | Ok ()   -> Ok ()
    | Error e -> Error e
end

let () =
  Eio_main.run @@ fun env ->
    let obs = Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
                ~service:BroadcastWorker.group_id () in
    match Kafka_service.config_of_env () with
    | Error e -> failwith (Kafka_service.error_to_string e)
    | Ok config ->
      Worker.Make(BroadcastWorker).run ~env ~config ~ot:obs ()
      |> Result.map_error Worker.run_error_to_string
      |> function Ok () -> () | Error msg -> failwith msg
```

## ack semantics

`W.handle` does not receive (or call) an `ack`. `Make(W).run` commits the Kafka offset itself, and only after `W.handle` returns `Ok ()` — never before, and never on `Error`. This removes an entire class of app-level bugs: forgetting to ack, acking in the wrong branch, or acking before a side effect that can still fail. For at-least-once semantics this is the correct default; at-exactly-once is not supported in v1.

A failed commit is **not** treated like a handler failure. The side effect in `W.handle` already succeeded, so retrying it (as an `Error` from `W.handle` would) risks duplicating it. Instead:

- The commit failure is logged (`Warn`, or `Error` if fatal) and counted as `sol_worker_messages_total{status="ack_failed"}`.
- If `Kafka_error.is_fatal e` — a broken consumer, not a transient hiccup — it escalates to `Kafka_consumer.Error e`, stopping the worker the same way an exhausted retry budget would.
- Otherwise, the worker continues. The offset was never committed, so the message remains eligible for natural redelivery — no immediate duplicate side effect, no lost message.

## Error handling

- `W.handle` returning `Error msg` triggers the retry strategy. After the retry budget is exhausted, `run` returns `Error`.
- `W.handle` returning `Ok ()` but the subsequent ack failing: see [ack semantics](#ack-semantics) above — handled separately from retry, via `ack_failed`.
- Decode errors: default behavior from `Kafka_service.consume_partitioned` — logs to stderr, acks the message, continues. Override via `on_decode_error` by calling `Kafka_service.consume_partitioned` directly.
- Lifecycle errors (`create`, `register`, Kafka error) are returned as `run_error` values.

## Test injection

`?_consume_loop` bypasses `Kafka_service.create/register/consume_partitioned` entirely, driving the wrapped handler with synthetic messages. Used in unit tests — not intended for production.

```ocaml
let fake_loop ~handler () =
  let _ = handler { id = "test-msg" } ~ack:(fun () -> Ok ()) ~trace_ctx:None in
  ()

Worker.Make(W).run ~env ~config ~_consume_loop:fake_loop ()
```
