(** Postgres-backed durable leased-job library (FEAT-077, DEC-021).

    [sol-jobs] gives Sol apps "do this eventually, retry with backoff, don't
    block on it" semantics for independent units of work, backed by the
    Postgres [pg-eio] every Sol app already provisions -- no new
    infrastructure, no new [local infra up] service, no second broker.

    This is a library, not a fourth deployable primitive: {!Make}[(J).run]
    is hosted by an ordinary generated [-worker] binary (the primitive with
    no HTTP surface and the natural home for long-running background
    execution) -- there is no [sol new jobs] app type. Runtime topology
    ([-svc]/[-worker]/[-fn]) and programming model (Kafka stream vs.
    [sol-jobs] leased job) are separate axes (DEC-021): a [-worker] binary
    that calls {!Make}[(J).run] instead of [Worker.Make(W).run] is still a
    [-worker] by deploy topology, it just processes a Postgres queue instead
    of a Kafka topic.

    [sol-jobs] deliberately does not provide Kafka-style ordering: jobs are
    claimed independently, in [run_at] order, with no partition/key concept
    and no cross-job sequencing guarantee. If a workload's correctness
    depends on strict per-key processing order, that is exactly what
    [sol-worker] against Kafka is for -- do not reach for [sol-jobs] merely
    because one job happens to relate to another. *)

(** Same vocabulary as [Kafka.Consumer.retry_policy] (FEAT-078's established
    shape), reimplemented independently here rather than pulling the
    [kafka-eio] package into a Postgres-only library. On failure, a job's
    [run_at] is set to (now + [base_delay_s * 2^(attempt-1)]), jittered by
    [jitter_ratio] and clamped to [max_delay_s]. [max_attempts]: total
    handler invocations, including the first, before a job is marked
    terminally failed. Negative = retry indefinitely. Must be [<> 0]. *)
type retry_policy =
  { base_delay_s : float
  ; max_delay_s : float
  ; max_attempts : int
  ; jitter_ratio : float
  }

(** [{ base_delay_s = 1.0; max_delay_s = 600.0; max_attempts = 5;
    jitter_ratio = 0.1 }]. [sol-jobs] is a durable at-least-once queue, not
    an infinite-retry stream consumer -- a bounded default that lands a
    poison job in the terminal failed state rather than retrying it forever
    is the safer default here, unlike [Kafka.Consumer]'s indefinite-by-
    default policy. *)
val default_retry_policy : retry_policy

(** One [Make] instance owns one shared job table and one polling loop. An
    app's [t] is its own sum type covering every kind of job it enqueues,
    e.g. [Send_welcome_email of { user_id : string } | Generate_pdf of
    { report_id : string }] -- multiple job "kinds" are just constructors of
    one [t], the same way an app's Kafka [MESSAGE] type can carry a variant
    payload. *)
module type JOB = sig
  type t

  (** A short, stable label for a job, e.g. ["send_welcome_email"]: it labels
      metrics and logs, and (BUG-044) it is what a poller claims by. *)
  val kind : t -> string

  (** Every value [kind] can return. A [Make(J)] poller claims only rows whose
      [kind] is in this list, so several [Make] instances with different job
      types can share the one [sol_jobs] table without claiming -- and then
      failing to decode -- each other's jobs. Each entry must be non-empty and
      use only [a-z], [0-9], [_], [.], [-]; [run] refuses anything else, and
      [enqueue] refuses a job whose [kind] is not listed (nobody would claim it). *)
  val kinds : string list

  (** Serialize a job to its stored [payload] text. JSON is the conventional
      choice (matching the rest of Sol's wire format) but not enforced. *)
  val encode : t -> string

  (** Deserialize a stored [payload]. [Error _] is treated exactly like a
      handler failure -- retried per {!retry_policy}, eventually terminal.
      There is no separate poison-message path the way Kafka's decode-error
      handling needs one: unlike a Kafka partition, one bad row can never
      block any other job's claim. *)
  val decode : string -> (t, string) result

  (** Called once per claimed job, outside any open database
      transaction/connection -- {!Make}[(J).run] does not hold a lease
      transaction open for the duration of [handle], only for the short
      claim/finalize queries around it. [Ok ()] completes (deletes) the
      job. [Error msg] schedules a retry per {!retry_policy}, or marks the
      job terminally failed (with [msg] recorded as [last_error]) once
      [max_attempts] is reached. *)
  val handle : t -> (unit, string) result
end

(** [`Config msg]: [run] was given something it cannot run with -- an invalid
    [retry_policy] ([max_attempts = 0]) or invalid [J.kinds] -- caught before
    the loop starts (the fail-fast discipline FEAT-078 applied to [sol-worker]).

    [`Database msg] (BUG-044): the job table cannot be used -- it does not exist
    or cannot be read when [run] starts, or [max_claim_failures] claims in a row
    failed. A missing migration or a lost database used to look exactly like an
    idle queue. *)
type run_error =
  [ `Config of string
  | `Database of string
  ]

val run_error_to_string : run_error -> string

module Make (J : JOB) : sig
  (** [enqueue pool ?run_at job] inserts a pending job row. [run_at] is a
      Unix timestamp in seconds, default now -- the job becomes claimable
      once [run_at] is reached. [enqueue] issues one plain [INSERT] and does
      not open a transaction of its own, so passing the [pool] handle from
      inside {!Db.transaction}'s callback enqueues the job atomically with
      whatever other application state change caused it (the transactional
      enqueue this library exists for) -- the very same function also works
      called standalone, outside any transaction. *)
  val enqueue : Pg_db.pool -> ?run_at:float -> J.t -> (unit, Pg_error.t) result

  (** Poll the shared job table, claiming and running due jobs one at a
      time until stopped. Mirrors [Worker.Make(_).run]'s shape
      ([env]/[ot]/[metrics_port]/[on_ready]/[stop]) so a [-worker] hosting
      [sol-jobs] looks and behaves like any other Sol primitive. *)
  val run
    :  env:(_, _, _, _) Sol_env.timed
    -> pool:Pg_db.pool
    -> ?retry_policy:retry_policy
    -> ?poll_interval_s:float
         (** How long to sleep when no claimable job was found. Default
             [1.0]. Never slept between consecutive jobs while the queue is
             non-empty -- the claim loop tries again immediately rather than
             waiting a full interval per job. *)
    -> ?lease_s:float
         (** How long a claimed job's lease lasts before another poller
             could reclaim it. Default [300.0] -- must comfortably exceed the
             slowest realistic [J.handle] call. The lease is never renewed: a
             [handle] that runs longer can see the job re-claimed and run
             concurrently elsewhere. Every finalize is fenced on the claimed
             attempt, so the stale holder cannot delete or unlock the new
             holder's claim, and both the overrun and the lost lease are
             logged (BUG-050). *)
    -> ?ot:Sol_obs.t
         (** Observability handle. When provided,
             [sol_jobs_processed_total{status}] (labels: [ok], [retry],
             [failed]) and [sol_jobs_job_duration_seconds] are emitted per
             job, and the loop exposes [GET /metrics] on [metrics_port] for
             Prometheus scraping -- the same metric shape [sol-worker]
             exposes, so a [-worker] hosting jobs is observable the same
             way. *)
    -> ?metrics_port:int
         (** Port for the [/metrics] endpoint above. Default [9090]. Only
             binds when [ot] is provided; pass [0] for an OS-assigned port
             (e.g. running more than one primitive in the same process, or
             in tests). *)
    -> ?on_ready:(unit -> unit)
         (** Called exactly once, before the first claim attempt. *)
    -> ?stop:unit Eio.Promise.t
         (** External stop signal. Resolve to request graceful shutdown;
             checked alongside SIGTERM/SIGINT, not in place of them. *)
    -> ?max_jobs:int
         (** Stop cleanly after this many jobs reach a terminal outcome
             (completed or permanently failed). *)
    -> ?max_claim_failures:int
         (** Consecutive failed claim queries after which [run] returns
             [`Database]. Default [30]. A transient blip is retried each
             [poll_interval_s]; a database that stays unreachable ends the
             process so it is restarted and seen, not left looking idle. *)
    -> unit
    -> (unit, run_error) result
end

module For_testing : sig
  (** Exposed so the backoff formula and config validation can be tested
      directly against [retry_policy] values without needing a live
      Postgres connection or a functor instance -- same reasoning as
      [kafka-eio]'s own [backoff_s] test seam. *)
  val backoff_s : rng:Random.State.t -> retry_policy -> int -> float

  val validate_retry_policy : retry_policy -> (unit, run_error) result
  val validate_kinds : string list -> (unit, run_error) result
end
