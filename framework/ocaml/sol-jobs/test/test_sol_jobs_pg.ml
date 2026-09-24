(* BUG-044 / FND-0036, against a real Postgres (POSTGRES_URL; skipped when unset).

   (a) The claim ignored [kind], so two [Make] instances sharing the one
       [sol_jobs] table claimed, failed to decode, and eventually marked 'failed'
       each other's jobs.
   (c) Every database failure went through a logger that was a no-op without
       [?ot], and a failing claim looped forever -- a missing table looked exactly
       like an idle queue. *)

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
       inserted_at  TIMESTAMPTZ NOT NULL DEFAULT now())|}
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

(* Two job types that decode only their own payload, as two independent
   modules sharing the table would. *)
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
    (match Reports.enqueue pool "q3" with
     | Ok () -> ()
     | Error e -> Alcotest.failf "enqueue report: %s" (Pg_error.to_string e));
    (match Emails.enqueue pool "alice" with
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
      [ "build_report", "pending", 0 ]
      (rows pool))
;;

let test_missing_table_is_a_startup_error () =
  with_pool (fun env pool ->
    exec_sql pool "DROP TABLE IF EXISTS sol_jobs";
    (* A high failure limit and a short timeout: only the startup check, not the
       consecutive-failure limit, can produce `Database in time. *)
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
    (match Strays.enqueue pool "x" with
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
         (* The table disappears after the startup check passed. *)
         Eio.Time.sleep env#clock 0.3;
         exec_sql pool "DROP TABLE sol_jobs");
    match !result with
    | Some (Ok (Error (`Database _))) -> ()
    | Some (Ok (Error (`Config m))) -> Alcotest.failf "unexpected `Config %s" m
    | Some (Ok (Ok ())) -> Alcotest.fail "run returned Ok while every claim failed"
    | Some (Error `Timeout) -> Alcotest.fail "run kept looping on a failing claim"
    | None -> Alcotest.fail "run did not report")
;;

(* ── BUG-050: finalize is fenced on the claimed attempt ────────────────── *)

(* Set by each test: the pool, so [Slow.handle] can re-claim its own job the way
   a second poller would once the lease expired. *)
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

(* Run [f] with fd 2 redirected to a file; return what was written. *)
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

let run_slow ?retry_policy ?stop ?lease_s ?max_jobs env pool =
  match
    Slows.run ~env ~pool ?retry_policy ?stop ?lease_s ?max_jobs ~poll_interval_s:0.05 ()
  with
  | Ok () -> ()
  | Error e -> Alcotest.fail (Sol_jobs.run_error_to_string e)
;;

let enqueue_slow pool =
  match Slows.enqueue pool "work" with
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

let test_lease_overrun_is_logged () =
  with_pool (fun env pool ->
    List.iter (exec_sql pool) ddl;
    current_pool := Some pool;
    enqueue_slow pool;
    (Slow.on_handle
     := fun () ->
          Unix.sleepf 0.3;
          Ok ());
    let (), err = capture_stderr (fun () -> run_slow ~lease_s:0.1 ~max_jobs:1 env pool) in
    Alcotest.(check bool) "overrun logged" true (contains ~needle:"lease overrun" err);
    Alcotest.(check int) "its own fenced finalize still won" 0 (List.length (rows pool)))
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
        ; Alcotest.test_case "lease overrun is logged" `Quick test_lease_overrun_is_logged
        ] )
    ]
;;
