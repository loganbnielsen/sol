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
  val kinds : string list
  val encode : t -> string
  val decode : string -> (t, string) result
  val handle : t -> (unit, string) result
end

type run_error =
  [ `Config of string
  | `Database of string
  ]

let run_error_to_string = function
  | `Config msg -> "sol-jobs: invalid configuration: " ^ msg
  | `Database msg -> "sol-jobs: job table unusable: " ^ msg
;;

let validate_retry_policy (policy : retry_policy) =
  let non_negative_finite name value =
    if Float.is_finite value && value >= 0.0
    then Ok ()
    else
      Error
        (`Config
            (Printf.sprintf
               "retry_policy.%s must be a finite number >= 0 (got %s)"
               name
               (Float.to_string value)))
  in
  if policy.max_attempts = 0
  then Error (`Config "retry_policy.max_attempts must be nonzero (negative = unlimited)")
  else (
    match non_negative_finite "base_delay_s" policy.base_delay_s with
    | Error _ as e -> e
    | Ok () ->
      (match non_negative_finite "max_delay_s" policy.max_delay_s with
       | Error _ as e -> e
       | Ok () ->
         if
           Float.is_finite policy.jitter_ratio
           && policy.jitter_ratio >= 0.0
           && policy.jitter_ratio <= 1.0
         then Ok ()
         else
           Error
             (`Config
                 (Printf.sprintf
                    "retry_policy.jitter_ratio must be a finite number within [0, 1] \
                     (got %s)"
                    (Float.to_string policy.jitter_ratio)))))
;;

let validate_timing ~poll_interval_s ~lease_s =
  let positive_finite name value =
    if Float.is_finite value && value > 0.0
    then Ok ()
    else
      Error
        (`Config
            (Printf.sprintf
               "%s must be a finite number > 0 (got %s)"
               name
               (Float.to_string value)))
  in
  match positive_finite "poll_interval_s" poll_interval_s with
  | Error _ as e -> e
  | Ok () -> positive_finite "lease_s" lease_s
;;

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

let is_kind_char = function
  | 'a' .. 'z' | '0' .. '9' | '_' | '.' | '-' -> true
  | _ -> false
;;

let validate_kinds kinds =
  match List.find_opt (fun k -> k = "" || not (String.for_all is_kind_char k)) kinds with
  | _ when kinds = [] ->
    Error (`Config "J.kinds is empty -- a poller that claims no kind would do nothing")
  | Some bad ->
    Error
      (`Config
          (Printf.sprintf
             "J.kinds entry %S is invalid: kinds are non-empty and use only a-z, 0-9, _, \
              ., -"
             bad))
  | None -> Ok ()
;;

module For_testing = struct
  let backoff_s = backoff_s
  let validate_retry_policy = validate_retry_policy
  let validate_timing = validate_timing
  let validate_kinds = validate_kinds
end

let table = "sol_jobs"

let claim_q =
  Caqti_request.Infix.(
    Caqti_type.(t2 float string) ->? Caqti_type.(t4 int string string int))
    (Printf.sprintf
       {|UPDATE %s
         SET locked_until = now() + (?::float8 * interval '1 second'),
             attempts = attempts + 1
         WHERE id = (
           SELECT id FROM %s
           WHERE status = 'pending'
             AND kind = ANY(string_to_array(?, ','))
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
  Caqti_request.Infix.(Caqti_type.(t2 int int) ->? Caqti_type.int)
    (Printf.sprintf "DELETE FROM %s WHERE id = ? AND attempts = ? RETURNING id" table)
;;

let retry_q =
  Caqti_request.Infix.(Caqti_type.(t4 float string int int) ->? Caqti_type.int)
    (Printf.sprintf
       {|UPDATE %s
         SET run_at = now() + (?::float8 * interval '1 second'),
             locked_until = NULL,
             last_error = ?
         WHERE id = ? AND attempts = ?
         RETURNING id|}
       table)
;;

let fail_q =
  Caqti_request.Infix.(Caqti_type.(t3 string int int) ->? Caqti_type.int)
    (Printf.sprintf
       {|UPDATE %s SET status = 'failed', locked_until = NULL, last_error = ?
         WHERE id = ? AND attempts = ?
         RETURNING id|}
       table)
;;

let table_check_q =
  Caqti_request.Infix.(Caqti_type.unit ->? Caqti_type.int)
    (Printf.sprintf "SELECT 1 FROM %s LIMIT 1" table)
;;

let default_max_claim_failures = 30
let default_metrics_port = 9090
let default_poll_interval_s = 1.0
let default_lease_s = 300.0

let with_runtime_unflushed
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

let with_runtime ~env ~ot ~metrics_port ~stop ~max_jobs ~body =
  let result = with_runtime_unflushed ~env ~ot ~metrics_port ~stop ~max_jobs ~body in
  Option.iter (fun o -> Sol_obs.flush o) ot;
  result
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
    let kind = J.kind job in
    if not (List.mem kind J.kinds)
    then
      Error
        (Pg_error.Query_error
           (Printf.sprintf
              "sol-jobs: kind %S is not in J.kinds; nothing would claim it"
              kind))
    else Pg_db.exec pool insert_q (kind, J.encode job, run_at)
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
        ?(max_claim_failures = default_max_claim_failures)
        ()
    =
    let open Result.Syntax in
    let* () = validate_retry_policy retry_policy in
    let* () = validate_timing ~poll_interval_s ~lease_s in
    let* () = validate_kinds J.kinds in
    let* () =
      match Pg_db.find pool table_check_q () with
      | Ok _ -> Ok ()
      | Error e ->
        Error
          (`Database
              (Printf.sprintf
                 "cannot read the %s table (an app migration must create it -- see \
                  sol-jobs.md): %s"
                 table
                 (Pg_error.to_string e)))
    in
    let kinds_param = String.concat "," J.kinds in
    with_runtime
      ~env
      ~ot
      ~metrics_port
      ~stop
      ~max_jobs
      ~body:(fun ~sw:_ ~ot ~job_count ~job_duration ~should_stop ~record_terminal ->
        Option.iter (fun f -> f ()) on_ready;
        let log_warn fields msg =
          match ot with
          | Some o -> Obs_eio.log_standalone o Obs_eio.Warn ~fields msg
          | None ->
            Printf.eprintf
              "%s %s\n%!"
              msg
              (String.concat " " (List.map (fun (k, v) -> k ^ "=" ^ v) fields))
        in
        let count status ~kind =
          match job_count with
          | Some c -> c ~labels:[ "status", status; "kind", kind ] 1
          | None -> ()
        in
        let lease_lost id ~attempts ~action =
          log_warn
            [ "job_id", string_of_int id
            ; "attempt", string_of_int attempts
            ; "action", action
            ]
            "sol-jobs: lease lost -- the job was re-claimed while this handler ran; this \
             outcome was not recorded and the job may have run concurrently"
        in
        let finalize_success id ~kind ~attempts ~t0 =
          (match Pg_db.find pool complete_q (id, attempts) with
           | Ok (Some _) -> ()
           | Ok None -> lease_lost id ~attempts ~action:"complete"
           | Error e ->
             log_warn
               [ "job_id", string_of_int id; "error", Pg_error.to_string e ]
               "sol-jobs: failed to delete completed job (will be reclaimed after its \
                lease expires and re-run)");
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
            (match Pg_db.find pool fail_q (msg, id, attempts) with
             | Ok (Some _) -> ()
             | Ok None -> lease_lost id ~attempts ~action:"fail"
             | Error e ->
               log_warn
                 [ "job_id", string_of_int id; "error", Pg_error.to_string e ]
                 "sol-jobs: failed to mark job permanently failed");
            count "failed" ~kind;
            record_terminal ())
          else (
            let delay = locked_backoff_s retry_policy attempts in
            (match Pg_db.find pool retry_q (delay, msg, id, attempts) with
             | Ok (Some _) -> ()
             | Ok None -> lease_lost id ~attempts ~action:"retry"
             | Error e ->
               log_warn
                 [ "job_id", string_of_int id; "error", Pg_error.to_string e ]
                 "sol-jobs: failed to schedule job retry (will be reclaimed after its \
                  lease expires and re-run)");
            count "retry" ~kind)
        in
        let rec loop ~failures =
          if should_stop ()
          then Ok ()
          else (
            match Pg_db.find pool claim_q (lease_s, kinds_param) with
            | Error e when failures + 1 >= max_claim_failures ->
              Error
                (`Database
                    (Printf.sprintf
                       "%d consecutive claim queries failed; last: %s"
                       (failures + 1)
                       (Pg_error.to_string e)))
            | Error e ->
              log_warn
                [ "error", Pg_error.to_string e
                ; "consecutive_failures", string_of_int (failures + 1)
                ]
                "sol-jobs: claim query failed";
              Eio.Time.sleep env#clock poll_interval_s;
              loop ~failures:(failures + 1)
            | Ok None ->
              Eio.Time.sleep env#clock poll_interval_s;
              loop ~failures:0
            | Ok (Some (id, kind, payload, attempts)) ->
              let t0 = Eio.Time.now env#clock in
              let outcome = Result.bind (J.decode payload) J.handle in
              let elapsed = Eio.Time.now env#clock -. t0 in
              if elapsed > lease_s
              then
                log_warn
                  [ "job_id", string_of_int id
                  ; "kind", kind
                  ; "elapsed_s", Printf.sprintf "%.1f" elapsed
                  ; "lease_s", Printf.sprintf "%.1f" lease_s
                  ]
                  "sol-jobs: lease overrun -- the handler ran longer than lease_s, so \
                   another poller may have claimed the job meanwhile; raise ?lease_s";
              (match outcome with
               | Ok () -> finalize_success id ~kind ~attempts ~t0
               | Error msg -> finalize_failure id ~kind ~attempts ~t0 ~msg);
              loop ~failures:0)
        in
        loop ~failures:0)
  ;;
end
