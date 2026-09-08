# Obs_prometheus.push (used by sol-fn)

The `push` function (from the external `obs-prometheus-eio` package) is called by
`Sol.Fn.Make` at the end of every invocation to push
metrics to a Prometheus Pushgateway. It is the correct solution for ephemeral processes
that cannot be scraped.

## Signature

```ocaml
val push
  :  net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> url:string        (* Pushgateway base URL, e.g. "http://localhost:9091" *)
  -> job:string        (* job label, e.g. "payments-fn" *)
  -> (unit -> string)  (* renderer from Obs_prometheus.create () *)
  -> (unit, string) result
```

## Behaviour

- Builds the Pushgateway PUT URL: `<url>/metrics/job/<job>`
- Calls the renderer to snapshot current metrics
- If the snapshot is empty (no metrics emitted), returns `Ok ()` immediately
- Otherwise PUTs the Prometheus text body to the Pushgateway
- Uses a 5-second wall-clock timeout via `Eio.Time.with_timeout_exn`
- Returns `Ok ()` on HTTP 2xx, `Error msg` otherwise
- Never raises — all errors surface as `Error _`

---

# sol-fn — Function Primitive

`sol-fn` implements the `-fn` primitive: a unit of business logic that executes once
and exits. In v1 the only trigger is a cron schedule deployed as a Kubernetes CronJob.

## Module type

```ocaml
module type FN = sig
  val schedule : string                        (* cron expression *)
  val run : unit -> (unit, string) result
end
```

## Functor

```ocaml
module Make (F : FN) : sig
  val run
    :  env:< net : _ Eio.Net.t; clock : _ Eio.Time.clock;
             mono_clock : _ Eio.Time.Mono.t; .. >
    -> ?pushgateway_url:string
    -> ?job:string
    -> ?backend:(Obs_eio.backend * (unit -> string))
    -> unit
    -> unit
end
```

## Lifecycle

1. Create Prometheus backend+renderer (or use `~backend` override)
2. Register `sol_fn_invocations_total{status}` counter and `sol_fn_duration_seconds` histogram
3. Record `t0`
4. `Switch.run`:  install signal handler (self-pipe); `Fiber.first` returning typed outcome
5. Record duration + increment counter — **outside** Fiber.first, so never cancelled
6. Push to Pushgateway if `~pushgateway_url` provided; all exceptions swallowed
7. `Ok ()` → return; function failure → `Error (`Run msg)`; signal → `Error `Signalled`

## Signal handling

Uses the self-pipe pattern from `http/sol-svc/lib/service.ml`. `Eio_unix.Signal` does not
exist in the installed eio version; the self-pipe approach is async-signal-safe and proven.

## Generated main

```ocaml
(* app/payments/deposit-fn/bin/main.ml *)
let () =
  Eio_main.run @@ fun env ->
    let module M = Sol_fn.Fn.Make(Deposit_fn) in
    match M.run ~env ~pushgateway_url:"http://pushgateway:9091" () with
    | Ok () -> ()
    | Error `Signalled -> exit 130
    | Error e -> failwith (Sol_fn.Fn.run_error_to_string e)
```

## Exit codes

| Condition | Exit code |
|---|---|
| `F.run ()` = `Ok ()` | 0 |
| `F.run ()` = `Error _` | caller policy, generated main exits non-zero |
| Ordinary exception from `F.run ()` | caller policy, generated main exits non-zero |
| SIGTERM / SIGINT | 130 |
