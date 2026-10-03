# sol-retry

A bounded, jittered, non-blocking **operation**-retry helper. It retries a dependency call —
the thing that actually failed transiently — inside the handler that made it.

```text
handler / request / invocation
      → Sol_retry.run policy (fun () -> dependency call)   ← retried here
      → Ok | the last error (the caller decides what it means)
```

It is the ergonomic half of DEC-021's 2026-09-29 amendment. The amendment removes
message-level retry: the worker outcome vocabulary is exactly `Ack | Fail`, a `Fail` leaves the
offset uncommitted and stops the consumer, and there is no retry topic. A transient Postgres,
HTTP or object-store failure is therefore retried **at the call that failed**, never by running
the handler again and never by re-reading the message.

## The contract

- **Bounded.** `max_attempts` is the total number of attempts, not the number of retries. A
  negative value means unbounded; zero is refused when the policy is validated.
- **Jittered and capped.** The delay before attempt `n + 1` is
  `min max_delay_s (base_delay_s * 2^(n - 1))`, spread by up to `jitter_ratio` either side so a
  fleet of callers does not retry in lockstep, and never negative.
- **Non-blocking.** Between attempts it yields to Eio (`Eio.Time.sleep`), so other fibers keep
  running; it never busy-waits and never blocks the domain.
- **The last error is the result.** When attempts run out, `run` returns the error from the
  final attempt. Exhaustion is not an exception and not a crash: the caller decides whether that
  is a `Fail`, a 5xx, a non-zero exit, or a job.
- **Cancellation wins.** `Eio.Cancel.Cancelled` propagates out of `run` unchanged; a cancelled
  caller stops retrying rather than finishing its budget.
- **Operations, never messages.** `run` takes a `unit -> ('a, 'e) result` thunk. It cannot
  re-run a handler, and it is not a route back to message-level retry.

## One vocabulary

The policy fields — `base_delay_s`, `max_delay_s`, `max_attempts`, `jitter_ratio` — are the
vocabulary `sol-jobs` and the worker retry machinery already use. `Sol_jobs.retry_policy` is
this type (`Sol_jobs.retry_policy = Sol_retry.policy`), `Sol_jobs.default_retry_policy` is
`Sol_retry.default_policy`, and `sol-jobs` computes its claim backoff with
`Sol_retry.backoff_s`. There is one retry vocabulary and one backoff formula in the framework,
not one per package.

## API

```ocaml
type policy =
  { base_delay_s : float
  ; max_delay_s : float
  ; max_attempts : int
  ; jitter_ratio : float
  }

val default_policy : policy
val validate : policy -> (unit, string) result
val backoff_s : rng:Random.State.t -> policy -> attempt:int -> float

type t

val of_policy : policy -> (t, string) result

val run
  :  clock:_ Eio.Time.clock
  -> ?rng:Random.State.t
  -> t
  -> (unit -> ('a, 'e) result)
  -> ('a, 'e) result
```

A valid policy is a type, not a promise: `of_policy` validates once and `run` accepts only the
result, so an unusable policy (`max_attempts = 0`) cannot reach the loop. The `~clock` is the
caller's, because the helper sleeps with it; in a `-svc`/`-worker`/`-fn` that is the
environment's clock (`env#clock`).

## Using it

```ocaml
let retry_policy =
  match
    Sol_retry.of_policy
      { base_delay_s = 0.25; max_delay_s = 5.0; max_attempts = 4; jitter_ratio = 0.25 }
  with
  | Ok policy -> policy
  | Error message -> failwith ("retry policy: " ^ message)
;;

let handle msg ~trace_ctx:_ : Worker.outcome =
  match
    Sol_retry.run ~clock:Config.clock retry_policy (fun () ->
      Pg_db.transaction Config.pool (fun tx -> apply_fact tx msg))
  with
  | Ok () -> Worker.Ack
  | Error error ->
    log_error error;
    Worker.Fail
;;
```

`examples/pluto`'s notify worker is this shape: the whole transaction is the operation, so a
transient failure retries the dependency call and the transaction rolls back on every failed
attempt. Because `handle` runs in the consumer's fiber, the functor carries the clock
(`val clock : float Eio.Time.clock_ty Eio.Resource.t`, instantiated with `env#clock`) — the
helper has no ambient clock to reach for.

`Sol_retry.run` is usable from all three primitives for the same reason: it depends on nothing
but Eio, so a `-svc` handler can retry an outbound peer call, a `-worker` its dependency write,
and a `-fn` its one-shot work.

## What it is not

- **Not message-level retry.** Retrying a message means re-running the handler, which would
  repeat whatever side effects already happened. The stream carries the fact; the handler is not
  retried.
- **Not a scheduler and not durable.** Nothing is persisted: if the process dies mid-backoff the
  work is gone unless the caller gave it a durable home. Independent work that must survive a
  restart goes to `sol-jobs`.
- **Not a policy engine.** Every error is retried; there is no per-error-class routing, no
  circuit breaker, no rate limiter.
- **Not idempotency.** A retried operation must be safe to run twice (a transaction that rolls
  back, an upsert, a conditional write). `run` cannot make an unsafe operation safe.
