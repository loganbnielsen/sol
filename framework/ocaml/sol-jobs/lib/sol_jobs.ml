type retry_policy =
  { base_delay_s : float
  ; max_delay_s : float
  ; max_attempts : int
  ; jitter_ratio : float
  }

let default_retry_policy =
  { base_delay_s = 1.0; max_delay_s = 600.0; max_attempts = 5; jitter_ratio = 0.1 }
;;

module type JOB = sig
  type t

  val kind : t -> string
  val encode : t -> string
  val decode : string -> (t, string) result
  val handle : t -> (unit, string) result
end

type run_error = [ `Config of string ]

let run_error_to_string = function
  | `Config msg -> "sol-jobs: invalid configuration: " ^ msg
;;

let validate_retry_policy (policy : retry_policy) =
  if policy.max_attempts = 0
  then Error (`Config "retry_policy.max_attempts must be nonzero (negative = unlimited)")
  else Ok ()
;;

(* Same self-seeded, mutex-protected Random.State.t discipline kafka-eio's
   Kafka_consumer uses for its own backoff jitter -- never the bare global
   Random module, and never a fresh unseeded state per call. *)
let default_rng = Random.State.make_self_init ()
let default_rng_mutex = Mutex.create ()

let backoff_s ~rng policy attempt =
  let raw = policy.base_delay_s *. (2. ** Float.of_int (attempt - 1)) in
  if policy.jitter_ratio <= 0.0
  then Float.min policy.max_delay_s (Float.max 0.0 raw)
  else (
    let jitter_unit = Random.State.float rng (2.0 *. policy.jitter_ratio) in
    let jittered = raw *. (1.0 +. (jitter_unit -. policy.jitter_ratio)) in
    Float.min policy.max_delay_s (Float.max 0.0 jittered))
;;

let locked_backoff_s policy attempt =
  Mutex.lock default_rng_mutex;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock default_rng_mutex)
    (fun () -> backoff_s ~rng:default_rng policy attempt)
;;

module For_testing = struct
  let backoff_s = backoff_s
  let validate_retry_policy = validate_retry_policy
end

(* ── SQL (fixed table name -- sol-jobs owns "sol_jobs", not configurable;
   see sol-jobs.md for the exact DDL an app's own migration must create) ── *)

let table = "sol_jobs"

let claim_q =
  Caqti_request.Infix.(Caqti_type.float ->? Caqti_type.(t4 int string string int))
    (Printf.sprintf
       {|UPDATE %s
         SET locked_until = now() + (?::float8 * interval '1 second'),
             attempts = attempts + 1
         WHERE id = (
           SELECT id FROM %s
           WHERE status = 'pending'
             AND run_at <= now()
             AND (locked_until IS NULL OR locked_until <= now())
           ORDER BY run_at
           FOR UPDATE SKIP LOCKED
           LIMIT 1
         )
         RETURNING id, kind, payload, attempts|}
       table
       table)
;;

let complete_q =
  Caqti_request.Infix.(Caqti_type.int ->. Caqti_type.unit)
    (Printf.sprintf "DELETE FROM %s WHERE id = ?" table)
;;

let retry_q =
  Caqti_request.Infix.(Caqti_type.(t3 float string int) ->. Caqti_type.unit)
    (Printf.sprintf
       {|UPDATE %s
         SET run_at = now() + (?::float8 * interval '1 second'),
             locked_until = NULL,
             last_error = ?
         WHERE id = ?|}
       table)
;;

let fail_q =
  Caqti_request.Infix.(Caqti_type.(t2 string int) ->. Caqti_type.unit)
    (Printf.sprintf
       {|UPDATE %s SET status = 'failed', locked_until = NULL, last_error = ? WHERE id = ?|}
       table)
;;

(* ── Shared runtime harness (mirrors Worker.with_runtime's shape) ──────── *)

let default_metrics_port = 9090
let default_poll_interval_s = 1.0
let default_lease_s = 300.0

let with_runtime
      ~(env : (_, _, _, _) Sol_env.timed)
      ~ot
      ~metrics_port
      ~stop
      ~max_jobs
      ~body
  =
  let metrics_renderer = Option.map Sol_obs.metrics_renderer ot in
  let obs_eio_t = Option.map Sol_obs.obs_eio ot in
  let job_count, job_duration =
    match obs_eio_t with
    | None -> None, None
    | Some o ->
      let c, h =
        Obs_eio.register_counter_and_histogram
          o
          ~counter_name:"sol_jobs_processed_total"
          ~counter_help:"Total jobs processed by status"
          ~counter_labels:[ "status"; "kind" ]
          ~histogram_name:"sol_jobs_job_duration_seconds"
          ~histogram_help:"Job handler duration in seconds"
          ~histogram_labels:[]
      in
      Some c, Some h
  in
  let signal_stop, signal_stop_r = Eio.Promise.create () in
  let remaining =
    match max_jobs with
    | Some n -> Some (ref n)
    | None -> None
  in
  let should_stop () =
    Eio.Promise.is_resolved signal_stop
    || (match stop with
        | Some p -> Eio.Promise.is_resolved p
        | None -> false)
    ||
    match remaining with
    | Some r -> !r <= 0
    | None -> false
  in
  (* Called once per job that reaches a terminal outcome (completed or
     permanently failed) -- a retried job is not "done" yet, so it does not
     count against max_jobs. *)
  let record_terminal () = Option.iter (fun r -> decr r) remaining in
  Eio.Switch.run (fun sw ->
    Sol_runtime.install_signal_handler ~sw signal_stop_r;
    Option.iter
      (fun render ->
         Obs_prometheus.serve
           ~sw
           ~net:env#net
           (`Tcp (Eio.Net.Ipaddr.V4.any, metrics_port))
           render)
      metrics_renderer;
    body ~sw ~ot:obs_eio_t ~job_count ~job_duration ~should_stop ~record_terminal)
;;

module Make (J : JOB) = struct
  let enqueue pool ?run_at (job : J.t) =
    let insert_q =
      Caqti_request.Infix.(Caqti_type.(t3 string string float) ->. Caqti_type.unit)
        (Printf.sprintf
           "INSERT INTO %s (kind, payload, run_at) VALUES (?, ?, to_timestamp(?))"
           table)
    in
    let run_at = Option.value run_at ~default:(Unix.gettimeofday ()) in
    Pg_db.exec pool insert_q (J.kind job, J.encode job, run_at)
  ;;

  let run
        ~(env : (_, _, _, _) Sol_env.timed)
        ~pool
        ?(retry_policy = default_retry_policy)
        ?(poll_interval_s = default_poll_interval_s)
        ?(lease_s = default_lease_s)
        ?ot
        ?(metrics_port = default_metrics_port)
        ?on_ready
        ?stop
        ?max_jobs
        ()
    =
    match validate_retry_policy retry_policy with
    | Error e -> Error e
    | Ok () ->
      Ok
        (with_runtime
           ~env
           ~ot
           ~metrics_port
           ~stop
           ~max_jobs
           ~body:(fun ~sw:_ ~ot ~job_count ~job_duration ~should_stop ~record_terminal ->
             Option.iter (fun f -> f ()) on_ready;
             let log_warn fields msg =
               match ot with
               | None -> ()
               | Some o -> Obs_eio.log_standalone o Obs_eio.Warn ~fields msg
             in
             let count status ~kind =
               match job_count with
               | Some c -> c ~labels:[ "status", status; "kind", kind ] 1
               | None -> ()
             in
             let finalize_success id ~kind ~t0 =
               (match Pg_db.exec pool complete_q id with
                | Ok () -> ()
                | Error e ->
                  log_warn
                    [ "job_id", string_of_int id; "error", Pg_error.to_string e ]
                    "sol-jobs: failed to delete completed job (will be reclaimed after \
                     its lease expires and re-run)");
               (match job_duration with
                | Some h -> h (Eio.Time.now env#clock -. t0)
                | None -> ());
               count "ok" ~kind;
               record_terminal ()
             in
             let finalize_failure id ~kind ~attempts ~t0 ~msg =
               (match job_duration with
                | Some h -> h (Eio.Time.now env#clock -. t0)
                | None -> ());
               let exhausted =
                 retry_policy.max_attempts >= 0 && attempts >= retry_policy.max_attempts
               in
               if exhausted
               then (
                 (match Pg_db.exec pool fail_q (msg, id) with
                  | Ok () -> ()
                  | Error e ->
                    log_warn
                      [ "job_id", string_of_int id; "error", Pg_error.to_string e ]
                      "sol-jobs: failed to mark job permanently failed");
                 count "failed" ~kind;
                 record_terminal ())
               else (
                 let delay = locked_backoff_s retry_policy attempts in
                 (match Pg_db.exec pool retry_q (delay, msg, id) with
                  | Ok () -> ()
                  | Error e ->
                    log_warn
                      [ "job_id", string_of_int id; "error", Pg_error.to_string e ]
                      "sol-jobs: failed to schedule job retry (will be reclaimed after \
                       its lease expires and re-run)");
                 count "retry" ~kind)
             in
             let rec loop () =
               if should_stop ()
               then ()
               else (
                 match Pg_db.find pool claim_q lease_s with
                 | Error e ->
                   log_warn
                     [ "error", Pg_error.to_string e ]
                     "sol-jobs: claim query failed";
                   Eio.Time.sleep env#clock poll_interval_s;
                   loop ()
                 | Ok None ->
                   Eio.Time.sleep env#clock poll_interval_s;
                   loop ()
                 | Ok (Some (id, kind, payload, attempts)) ->
                   let t0 = Eio.Time.now env#clock in
                   (match J.decode payload with
                    | Error msg -> finalize_failure id ~kind ~attempts ~t0 ~msg
                    | Ok job ->
                      (match J.handle job with
                       | Ok () -> finalize_success id ~kind ~t0
                       | Error msg -> finalize_failure id ~kind ~attempts ~t0 ~msg));
                   loop ())
             in
             loop ()))
  ;;
end
