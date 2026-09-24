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
and exits: on a schedule as a Kubernetes CronJob (`Cron`), or hosted on AWS Lambda
(`Lambda`).

## Module type

```ocaml
type trigger = Cron | Lambda

module type FN = sig
  val trigger : trigger
  val run : unit -> (unit, string) result
end
```

**The schedule lives in `sol.toml`, and only there** (BUG-048): `[service] schedule` in
the workload's `sol.toml` is required for a `-fn`. A missing one is a plan error; it
used to default to hourly. The code carries no cron string, so the two cannot disagree.

## Functor

```ocaml
module Make (F : FN) : sig
  val run
    :  env:< net : _ Eio.Net.t; clock : _ Eio.Time.clock;
             mono_clock : _ Eio.Time.Mono.t; .. >
    -> ?pushgateway_url:string   (* default: PUSHGATEWAY_URL from the environment *)
    -> ?job:string               (* default: SOL_PUSHGATEWAY_JOB, else "sol-fn"/"lambda" *)
    -> ?ot:Sol_obs.t
    -> ?stop:unit Eio.Promise.t
    -> unit
    -> (unit, run_error) result
end
```

Sol's manifests render `PUSHGATEWAY_URL` and `SOL_PUSHGATEWAY_JOB=<namespace>.<name>`
into every `-fn`, so a generated `main` that passes neither still pushes, and each
function's metrics land in its own Pushgateway group. The job used to default to the
cron string, so two functions on one schedule overwrote each other (BUG-048).

## Lifecycle

1. Create Prometheus backend+renderer (or use `~backend` override)
2. Register `sol_fn_invocations_total{status}` counter and `sol_fn_duration_seconds` histogram
3. Record `t0`
4. `Switch.run`:  install signal handler (self-pipe); `Fiber.first` returning typed outcome
5. Record duration + increment counter — **outside** Fiber.first, so never cancelled
6. Push to Pushgateway if a URL is configured (`~pushgateway_url` or `PUSHGATEWAY_URL`); push errors are logged and never fail the run
7. `Ok ()` → return; function failure → `Error (`Run msg)`; signal → `Error `Signalled`

## Signal handling

Uses the self-pipe pattern from `http/sol-svc/lib/service.ml`. `Eio_unix.Signal` does not
exist in the installed eio version; the self-pipe approach is async-signal-safe and proven.

## Generated main

```ocaml
(* app/payments/deposit-fn/bin/main.ml *)
let () =
  Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let obs =
      Sol_obs.of_env ~sw ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
        ~service:"deposit-fn" ()
    in
    let module M = Fn.Make (Deposit_fn) in
    match M.run ~env ~ot:obs () with          (* URL and job come from the manifest env *)
    | Ok () -> ()
    | Error `Signalled -> exit 130
    | Error e -> failwith (Fn.run_error_to_string e)
```

## Exit codes

| Condition | Exit code |
|---|---|
| `F.run ()` = `Ok ()` | 0 |
| `F.run ()` = `Error _` | caller policy, generated main exits non-zero |
| Ordinary exception from `F.run ()` | caller policy, generated main exits non-zero |
| SIGTERM / SIGINT | 130 |

## Deployment: a run-once execution primitive (FEAT-079)

`-fn` is formally a **run-once Kubernetes execution primitive**, not "a cron
abstraction" — `Fn.Make(F).run` above has no cron awareness at all; it runs
`F.run` exactly once and exits. Cron is one invocation mechanism Sol wires
up (a Kubernetes `CronJob`); manual invocation (`sol fn run`, below) is the
other. Both create a Kubernetes `Job` from the *same* deployed `CronJob`'s
`jobTemplate` — there is exactly one execution definition, not one per
invocation source.

Two pieces of that `jobTemplate` are explicit `sol.toml` decisions rather
than Kubernetes defaults Sol silently inherited:

```toml
[service]
scheduled_concurrency = "forbid"   # allow (default) | forbid | replace
backoff_limit = 3                  # default: 3
```

- **`scheduled_concurrency`** renders as `CronJob.spec.concurrencyPolicy`
  (Kubernetes' own three-value enum, unchanged). It governs overlap between
  the **CronJob controller's own scheduled runs** only — a function whose
  execution can outlast its schedule interval either lets the next tick
  overlap it (`allow`, the default, preserving pre-FEAT-079 behavior),
  skips the next tick (`forbid`), or cancels the running execution and
  starts the next one (`replace`). **A manual invocation via `sol fn run` is
  never constrained by this value** — it is not a scheduled run, so
  `concurrencyPolicy` (which only Kubernetes' CronJob controller consults)
  never applies to it. Do not read `scheduled_concurrency = "forbid"` as "at
  most one execution of this function, period" — that is a different,
  stronger guarantee Sol does not currently provide.
- **`backoff_limit`** renders as `jobTemplate.spec.backoffLimit` (default:
  `3`, matching pre-FEAT-079 behavior). This is the end-to-end operational
  meaning of a handler's `Error _` above: `F.run ()` returning `Error _` (or
  raising) exits the process non-zero, Kubernetes' `restartPolicy:
  OnFailure` restarts the container, and after `backoff_limit` total
  failures the `Job` is marked failed and not retried again. `backoff_limit`
  is deliberately *not* named or documented as equivalent to `sol-worker`'s
  `retry_policy.max_attempts` (FEAT-078) — the two have not been checked for
  exact semantic equivalence (pod/container restart interactions in
  particular), so `backoff_limit` is exposed substrate-shaped rather than
  implying a stronger, shared contract it may not actually have.

Deliberately not made explicit (Kubernetes defaults apply, unchanged):
`activeDeadlineSeconds`, `startingDeadlineSeconds`,
`successfulJobsHistoryLimit`/`failedJobsHistoryLimit`, `suspend`.

## Manual invocation: `sol fn run` (FEAT-079)

```
sol fn run <domain>/<name> [--target ENV/PROVIDER/REGION]
sol local fn run <domain>/<name>
```

Creates one ad-hoc Kubernetes `Job` from the deployed `-fn`'s `CronJob`
(`kubectl create job --from=cronjob/...`), so a manual run executes exactly
the same `jobTemplate` — image, env, secrets, resources, `backoff_limit` —
that the next scheduled tick would. Sol does not reconstruct or store a
second copy of the execution definition from `sol.toml`/local source to do
this: the already-deployed `CronJob` is authoritative, the same way a
recorded release is authoritative for `sol rollback` (FEAT-066).

Not constrained by `scheduled_concurrency` — see above.
