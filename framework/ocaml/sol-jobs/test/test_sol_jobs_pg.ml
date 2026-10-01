let postgres_url = Sys.getenv_opt "POSTGRES_URL"

let ddl =
  [ "DROP TABLE IF EXISTS sol_jobs"
  ; {|CREATE TABLE sol_jobs (
       id           SERIAL      PRIMARY KEY,
       kind         TEXT        NOT NULL,
       payload      TEXT        NOT NULL,
       status       TEXT        NOT NULL DEFAULT 'pending',
       attempts     INT         NOT NULL DEFAULT 0,
       run_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
       locked_until TIMESTAMPTZ,
       last_error   TEXT,
       dedupe_key   TEXT,
       inserted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
       finished_at  TIMESTAMPTZ)|}
  ; "CREATE UNIQUE INDEX sol_jobs_dedupe_idx ON sol_jobs (kind, dedupe_key) WHERE \
     dedupe_key IS NOT NULL"
  ; "CREATE INDEX sol_jobs_terminal_idx ON sol_jobs (finished_at) WHERE status <> \
     'pending'"
  ]
;;

let exec_sql pool sql =
  match
    Pg_db.exec
      pool
      (Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true sql)
      ()
  with
  | Ok () -> ()
  | Error e -> Alcotest.failf "%s: %s" sql (Pg_error.to_string e)
;;

let rows pool =
  match
    Pg_db.collect
      pool
      (Caqti_request.Infix.(Caqti_type.unit ->* Caqti_type.(t3 string string int))
         ~oneshot:true
         "SELECT kind, status, attempts FROM sol_jobs ORDER BY id")
      ()
  with
  | Ok rows -> rows
  | Error e -> Alcotest.failf "select: %s" (Pg_error.to_string e)
;;

module Job (K : sig
    val kind : string
  end) =
struct
  type t = string

  let kind (_ : t) = K.kind
  let kinds = [ K.kind ]
  let encode t = K.kind ^ ":" ^ t

  let decode s =
    let prefix = K.kind ^ ":" in
    if String.starts_with ~prefix s
    then Ok (String.sub s (String.length prefix) (String.length s - String.length prefix))
    else Error ("not a " ^ K.kind ^ " payload: " ^ s)
  ;;

  let handled = ref []

  let handle t =
    handled := t :: !handled;
    Ok ()
  ;;
end

module Email = Job (struct
    let kind = "send_email"
  end)

module Report = Job (struct
    let kind = "build_report"
  end)

module Emails = Sol_jobs.Make (Email)
module Reports = Sol_jobs.Make (Report)

let with_pool f =
  match postgres_url with
  | None -> print_endline "[skip] POSTGRES_URL not set"
  | Some url ->
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    (match Pg_db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) () with
     | Error e -> Alcotest.failf "pool: %s" (Pg_error.to_string e)
     | Ok pool -> f env pool)
;;

let test_make_instances_do_not_cross_claim () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    (match Pg_db.transaction pool (fun tx -> Reports.enqueue tx "q3") with
     | Ok () -> ()
     | Error e -> Alcotest.failf "enqueue report: %s" (Pg_error.to_string e));
    (match Pg_db.transaction pool (fun tx -> Emails.enqueue tx "alice") with
     | Ok () -> ()
     | Error e -> Alcotest.failf "enqueue email: %s" (Pg_error.to_string e));
    Email.handled := [];
    (match Emails.run ~env ~pool ~poll_interval_s:0.05 ~max_jobs:1 () with
     | Ok () -> ()
     | Error e -> Alcotest.fail (Sol_jobs.run_error_to_string e));
    Alcotest.(check (list string))
      "the email poller ran its own job"
      [ "alice" ]
      !Email.handled;
    Alcotest.(check (list (triple string string int)))
      "the report job was not claimed by the email poller"
      [ "build_report", "pending", 0; "send_email", "completed", 1 ]
      (rows pool))
;;

let test_missing_table_is_a_startup_error () =
  with_pool (fun env pool ->
    exec_sql pool "DROP TABLE IF EXISTS sol_jobs";
    match
      Eio.Time.with_timeout env#clock 5.0 (fun () ->
        Ok (Emails.run ~env ~pool ~poll_interval_s:0.05 ~max_claim_failures:1000 ()))
      |> function
      | Ok r -> r
      | Error `Timeout ->
        Alcotest.fail "no startup error: run started polling a missing table"
    with
    | Error (`Database msg) ->
      let contains ~needle s =
        let n = String.length needle
        and m = String.length s in
        let rec go i = i + n <= m && (String.sub s i n = needle || go (i + 1)) in
        go 0
      in
      Alcotest.(check bool)
        "names the sol_jobs table"
        true
        (contains ~needle:"sol_jobs" msg)
    | Error (`Config m) -> Alcotest.failf "expected `Database, got `Config %s" m
    | Ok () -> Alcotest.fail "a missing sol_jobs table must not look like an idle queue")
;;

let test_enqueue_refuses_an_undeclared_kind () =
  with_pool (fun _env pool ->
    List.iter (exec_sql pool) ddl;
    let module Stray = struct
      include Email

      let kind (_ : t) = "not_declared"
    end
    in
    let module Strays = Sol_jobs.Make (Stray) in
    (match Pg_db.transaction pool (fun tx -> Strays.enqueue tx "x") with
     | Error _ -> ()
     | Ok () -> Alcotest.fail "a kind nothing claims must not be enqueued");
    Alcotest.(check int) "nothing was inserted" 0 (List.length (rows pool)))
;;

let test_persistent_claim_failure_ends_run () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    let result = ref None in
    Eio.Fiber.both
      (fun () ->
         result
         := Some
              (Eio.Time.with_timeout env#clock 20.0 (fun () ->
                 Ok (Emails.run ~env ~pool ~poll_interval_s:0.05 ~max_claim_failures:3 ()))))
      (fun () ->
         Eio.Time.sleep env#clock 0.3;
         exec_sql pool "DROP TABLE sol_jobs");
    match !result with
    | Some (Ok (Error (`Database _))) -> ()
    | Some (Ok (Error (`Config m))) -> Alcotest.failf "unexpected `Config %s" m
    | Some (Ok (Ok ())) -> Alcotest.fail "run returned Ok while every claim failed"
    | Some (Error `Timeout) -> Alcotest.fail "run kept looping on a failing claim"
    | None -> Alcotest.fail "run did not report")
;;

let current_pool = ref None

let reclaim_now () =
  match !current_pool with
  | None -> Alcotest.fail "no pool"
  | Some pool ->
    exec_sql
      pool
      "UPDATE sol_jobs SET attempts = attempts + 1, locked_until = now() + interval '1 \
       hour'"
;;

module Slow = struct
  type t = string

  let kind (_ : t) = "slow"
  let kinds = [ "slow" ]
  let encode t = t
  let decode s = Ok s
  let on_handle : (unit -> (unit, string) result) ref = ref (fun () -> Ok ())
  let handle (_ : t) = !on_handle ()
end

module Slows = Sol_jobs.Make (Slow)

let lease_state pool =
  match
    Pg_db.collect
      pool
      (Caqti_request.Infix.(Caqti_type.unit ->* Caqti_type.(t4 string int bool bool))
         ~oneshot:true
         "SELECT status, attempts, locked_until IS NOT NULL, last_error IS NOT NULL FROM \
          sol_jobs")
      ()
  with
  | Ok rows -> List.map (fun (st, n, locked, err) -> st, (n, locked, err)) rows
  | Error e -> Alcotest.failf "select: %s" (Pg_error.to_string e)
;;

let capture_stderr f =
  let path = Filename.temp_file "sol-jobs-stderr-" ".log" in
  let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let saved = Unix.dup Unix.stderr in
  Unix.dup2 fd Unix.stderr;
  Unix.close fd;
  let restore () =
    Unix.dup2 saved Unix.stderr;
    Unix.close saved
  in
  let result =
    match f () with
    | v ->
      restore ();
      v
    | exception e ->
      restore ();
      raise e
  in
  let out = In_channel.with_open_text path In_channel.input_all in
  Sys.remove path;
  result, out
;;

let contains ~needle s =
  let n = String.length needle
  and m = String.length s in
  let rec go i = i + n <= m && (String.sub s i n = needle || go (i + 1)) in
  go 0
;;

let run_slow
      ?retry_policy
      ?stop
      ?lease_s
      ?max_jobs
      ?terminal_retention_s
      ?sweep_interval_s
      env
      pool
  =
  match
    Slows.run
      ~env
      ~pool
      ?retry_policy
      ?stop
      ?lease_s
      ?max_jobs
      ?terminal_retention_s
      ?sweep_interval_s
      ~poll_interval_s:0.05
      ()
  with
  | Ok () -> ()
  | Error e -> Alcotest.fail (Sol_jobs.run_error_to_string e)
;;

let enqueue_slow ?dedupe_key pool =
  match Pg_db.transaction pool (fun tx -> Slows.enqueue tx ?dedupe_key "work") with
  | Ok () -> ()
  | Error e -> Alcotest.failf "enqueue: %s" (Pg_error.to_string e)
;;

let test_stale_complete_is_a_no_op () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    current_pool := Some pool;
    enqueue_slow pool;
    (Slow.on_handle
     := fun () ->
          reclaim_now ();
          Ok ());
    let (), err = capture_stderr (fun () -> run_slow ~max_jobs:1 env pool) in
    Alcotest.(check (list (pair string (triple int bool bool))))
      "the new holder's claim survives: not deleted, still locked"
      [ "pending", (2, true, false) ]
      (lease_state pool);
    Alcotest.(check bool)
      "the lost lease is logged"
      true
      (contains ~needle:"lease lost" err))
;;

let test_stale_fail_is_a_no_op () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    current_pool := Some pool;
    enqueue_slow pool;
    (Slow.on_handle
     := fun () ->
          reclaim_now ();
          Error "boom");
    let retry_policy =
      { Sol_jobs.base_delay_s = 0.0
      ; max_delay_s = 0.0
      ; max_attempts = 1
      ; jitter_ratio = 0.0
      }
    in
    let (), _ = capture_stderr (fun () -> run_slow ~retry_policy ~max_jobs:1 env pool) in
    Alcotest.(check (list (pair string (triple int bool bool))))
      "not marked failed, lease not cleared"
      [ "pending", (2, true, false) ]
      (lease_state pool))
;;

let test_stale_retry_is_a_no_op () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    current_pool := Some pool;
    enqueue_slow pool;
    let stop, stop_r = Eio.Promise.create () in
    (Slow.on_handle
     := fun () ->
          reclaim_now ();
          ignore (Eio.Promise.try_resolve stop_r ());
          Error "transient");
    let (), _ = capture_stderr (fun () -> run_slow ~stop env pool) in
    Alcotest.(check (list (pair string (triple int bool bool))))
      "retry did not clear the new holder's lease"
      [ "pending", (2, true, false) ]
      (lease_state pool))
;;

let test_long_handler_renews_lease () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    let started, started_r = Eio.Promise.create () in
    let stop, stop_r = Eio.Promise.create () in
    let handled = ref 0 in
    (Slow.on_handle
     := fun () ->
          incr handled;
          ignore (Eio.Promise.try_resolve started_r ());
          Eio.Time.sleep env#clock 0.5;
          Ok ());
    (match
       Eio.Time.with_timeout env#clock 5.0 (fun () ->
         Eio.Fiber.both
           (fun () -> run_slow ~lease_s:0.1 ~max_jobs:1 env pool)
           (fun () ->
              Eio.Promise.await started;
              Eio.Fiber.both
                (fun () -> run_slow ~lease_s:0.1 ~stop env pool)
                (fun () ->
                   Eio.Time.sleep env#clock 0.35;
                   ignore (Eio.Promise.try_resolve stop_r ())));
         Ok ())
     with
     | Ok () -> ()
     | Error `Timeout -> Alcotest.fail "pollers did not finish");
    Alcotest.(check int) "one handler ran" 1 !handled;
    Alcotest.(check (list (triple string string int)))
      "the completed row is retained, not deleted"
      [ "slow", "completed", 1 ]
      (rows pool))
;;

let test_lost_renewal_is_logged () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    current_pool := Some pool;
    enqueue_slow pool;
    (Slow.on_handle
     := fun () ->
          reclaim_now ();
          Eio.Time.sleep env#clock 0.15;
          Ok ());
    let (), err = capture_stderr (fun () -> run_slow ~lease_s:0.1 ~max_jobs:1 env pool) in
    Alcotest.(check bool) "lost renewal logged" true (contains ~needle:"action=renew" err);
    Alcotest.(check (list (pair string (triple int bool bool))))
      "new holder remains fenced"
      [ "pending", (2, true, false) ]
      (lease_state pool))
;;

let test_crashed_attempt_is_exhausted_at_claim () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    exec_sql
      pool
      "UPDATE sol_jobs SET attempts = 2, locked_until = now() - interval '1 second'";
    let handled = ref false in
    (Slow.on_handle
     := fun () ->
          handled := true;
          Ok ());
    let retry_policy = { Sol_jobs.default_retry_policy with max_attempts = 2 } in
    run_slow ~retry_policy ~max_jobs:1 env pool;
    Alcotest.(check bool) "handler not called" false !handled;
    Alcotest.(check (list (triple string string int)))
      "exhausted row failed without another attempt"
      [ "slow", "failed", 2 ]
      (rows pool);
    Alcotest.(check (list (pair string (triple int bool bool))))
      "crash failure is recorded without a live lease"
      [ "failed", (2, false, true) ]
      (lease_state pool))
;;

let test_unlimited_attempts_reclaim () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    exec_sql
      pool
      "UPDATE sol_jobs SET attempts = 2, locked_until = now() - interval '1 second'";
    let handled = ref false in
    (Slow.on_handle
     := fun () ->
          handled := true;
          Ok ());
    let retry_policy = { Sol_jobs.default_retry_policy with max_attempts = -1 } in
    run_slow ~retry_policy ~max_jobs:1 env pool;
    Alcotest.(check bool) "handler ran again" true !handled;
    Alcotest.(check (list (triple string string int)))
      "job completed and is retained"
      [ "slow", "completed", 3 ]
      (rows pool))
;;

let test_handler_exception_is_a_failed_attempt () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    (Slow.on_handle := fun () -> failwith "handler exploded");
    let retry_policy =
      { Sol_jobs.default_retry_policy with
        max_attempts = 2
      ; base_delay_s = 0.0
      ; max_delay_s = 0.0
      }
    in
    run_slow ~retry_policy ~max_jobs:1 env pool;
    Alcotest.(check (list (triple string string int)))
      "exception used the normal terminal failure path"
      [ "slow", "failed", 2 ]
      (rows pool))
;;

let test_expired_holder_cannot_complete_terminal_row () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    (Slow.on_handle
     := fun () ->
          exec_sql
            pool
            "UPDATE sol_jobs SET status = 'failed', locked_until = NULL, last_error = \
             'worker stopped before finishing the previous attempt'";
          Ok ());
    let retry_policy = { Sol_jobs.default_retry_policy with max_attempts = 1 } in
    let (), err =
      capture_stderr (fun () -> run_slow ~retry_policy ~lease_s:0.1 ~max_jobs:1 env pool)
    in
    Alcotest.(check (list (triple string string int)))
      "old holder did not delete terminal row"
      [ "slow", "failed", 1 ]
      (rows pool);
    Alcotest.(check bool)
      "the lost lease is logged"
      true
      (contains ~needle:"lease lost" err))
;;

let test_duplicate_enqueue_with_a_dedupe_key_is_a_no_op () =
  with_pool (fun _env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow ~dedupe_key:"evt-1" pool;
    enqueue_slow ~dedupe_key:"evt-1" pool;
    Alcotest.(check (list (triple string string int)))
      "one row for a repeated dedupe key"
      [ "slow", "pending", 0 ]
      (rows pool))
;;

let test_concurrent_duplicate_enqueue_inserts_one_row () =
  with_pool (fun _env pool ->
    List.iter (exec_sql pool) ddl;
    ignore
      (Eio.Fiber.both
         (fun () -> enqueue_slow ~dedupe_key:"evt-2" pool)
         (fun () -> enqueue_slow ~dedupe_key:"evt-2" pool));
    Alcotest.(check (list (triple string string int)))
      "the unique index admits exactly one of two concurrent inserts"
      [ "slow", "pending", 0 ]
      (rows pool))
;;

let test_omitted_dedupe_key_keeps_at_least_once () =
  with_pool (fun _env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow pool;
    enqueue_slow pool;
    Alcotest.(check int)
      "no dedupe key means no deduplication"
      2
      (List.length (rows pool)))
;;

let test_redelivery_after_completion_is_a_no_op () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow ~dedupe_key:"evt-3" pool;
    (Slow.on_handle := fun () -> Ok ());
    run_slow ~max_jobs:1 env pool;
    Alcotest.(check (list (triple string string int)))
      "the finished row is retained while its key is live"
      [ "slow", "completed", 1 ]
      (rows pool);
    enqueue_slow ~dedupe_key:"evt-3" pool;
    Alcotest.(check int)
      "a redelivery after completion enqueues nothing"
      1
      (List.length (rows pool)))
;;

let test_expired_terminal_row_releases_its_key () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    enqueue_slow ~dedupe_key:"evt-4" pool;
    (Slow.on_handle := fun () -> Ok ());
    run_slow ~terminal_retention_s:0.0 ~sweep_interval_s:0.0 ~max_jobs:1 env pool;
    Alcotest.(check int) "the expired terminal row was swept" 0 (List.length (rows pool));
    enqueue_slow ~dedupe_key:"evt-4" pool;
    Alcotest.(check int)
      "the key is reusable once its row is gone"
      1
      (List.length (rows pool)))
;;

let () =
  Alcotest.run
    "sol_jobs_pg"
    [ ( "claim by kind (BUG-044 a)"
      , [ Alcotest.test_case
            "two Make instances do not cross-claim"
            `Quick
            test_make_instances_do_not_cross_claim
        ; Alcotest.test_case
            "enqueue refuses an undeclared kind"
            `Quick
            test_enqueue_refuses_an_undeclared_kind
        ] )
    ; ( "database failures are loud (BUG-044 c)"
      , [ Alcotest.test_case
            "missing table is a startup error"
            `Quick
            test_missing_table_is_a_startup_error
        ; Alcotest.test_case
            "persistent claim failure ends run"
            `Quick
            test_persistent_claim_failure_ends_run
        ] )
    ; ( "lease fencing (BUG-050)"
      , [ Alcotest.test_case
            "stale complete is a no-op"
            `Quick
            test_stale_complete_is_a_no_op
        ; Alcotest.test_case "stale fail is a no-op" `Quick test_stale_fail_is_a_no_op
        ; Alcotest.test_case "stale retry is a no-op" `Quick test_stale_retry_is_a_no_op
        ; Alcotest.test_case
            "long handler renews its lease"
            `Quick
            test_long_handler_renews_lease
        ; Alcotest.test_case "lost renewal is logged" `Quick test_lost_renewal_is_logged
        ] )
    ; ( "bounded attempts (BUG-098)"
      , [ Alcotest.test_case
            "crashed attempts stop at the configured budget"
            `Quick
            test_crashed_attempt_is_exhausted_at_claim
        ; Alcotest.test_case
            "handler exceptions are failed attempts"
            `Quick
            test_handler_exception_is_a_failed_attempt
        ; Alcotest.test_case
            "unlimited attempts still reclaim"
            `Quick
            test_unlimited_attempts_reclaim
        ; Alcotest.test_case
            "expired holder cannot complete a terminal row"
            `Quick
            test_expired_holder_cannot_complete_terminal_row
        ] )
    ; ( "idempotent enqueue (FEAT-112)"
      , [ Alcotest.test_case
            "a repeated dedupe key is a no-op"
            `Quick
            test_duplicate_enqueue_with_a_dedupe_key_is_a_no_op
        ; Alcotest.test_case
            "concurrent duplicates insert one row"
            `Quick
            test_concurrent_duplicate_enqueue_inserts_one_row
        ; Alcotest.test_case
            "an omitted dedupe key keeps at-least-once"
            `Quick
            test_omitted_dedupe_key_keeps_at_least_once
        ; Alcotest.test_case
            "a redelivery after completion is a no-op"
            `Quick
            test_redelivery_after_completion_is_a_no_op
        ; Alcotest.test_case
            "an expired terminal row releases its key"
            `Quick
            test_expired_terminal_row_releases_its_key
        ] )
    ]
;;
