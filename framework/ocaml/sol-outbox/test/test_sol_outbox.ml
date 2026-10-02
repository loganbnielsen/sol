open Caqti_request.Infix
open Caqti_type
open Result.Syntax

let postgres_url () =
  match Sys.getenv_opt "POSTGRES_URL" with
  | Some "" -> None
  | v -> v
;;

let ddl =
  [ "DROP TABLE IF EXISTS sol_outbox"
  ; "CREATE TABLE sol_outbox (\n\
    \  id BIGSERIAL PRIMARY KEY,\n\
    \  kind TEXT NOT NULL,\n\
    \  aggregate_key TEXT NOT NULL,\n\
    \  ord BIGINT NOT NULL,\n\
    \  payload TEXT NOT NULL,\n\
    \  created_at TIMESTAMPTZ NOT NULL DEFAULT now())"
  ; "CREATE UNIQUE INDEX sol_outbox_key_ord_idx ON sol_outbox (aggregate_key, ord)"
  ]
;;

let jobs_ddl =
  [ "DROP TABLE IF EXISTS sol_jobs"
  ; "CREATE TABLE sol_jobs (\n\
    \  id SERIAL PRIMARY KEY,\n\
    \  kind TEXT NOT NULL,\n\
    \  payload TEXT NOT NULL,\n\
    \  status TEXT NOT NULL DEFAULT 'pending',\n\
    \  attempts INT NOT NULL DEFAULT 0,\n\
    \  run_at TIMESTAMPTZ NOT NULL DEFAULT now(),\n\
    \  locked_until TIMESTAMPTZ,\n\
    \  last_error TEXT,\n\
    \  dedupe_key TEXT,\n\
    \  inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),\n\
    \  finished_at TIMESTAMPTZ)"
  ; "CREATE UNIQUE INDEX sol_jobs_dedupe_idx ON sol_jobs (kind, dedupe_key) WHERE \
     dedupe_key IS NOT NULL"
  ]
;;

let exec_sql pool sql =
  match Pg_db.exec pool ((unit ->. unit) sql) () with
  | Ok () -> ()
  | Error e -> Alcotest.failf "%s: %s" sql (Pg_error.to_string e)
;;

let with_pool f =
  match postgres_url () with
  | None -> print_endline "[skip] POSTGRES_URL not set"
  | Some url ->
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    (match Pg_db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) () with
     | Error e -> Alcotest.failf "pool: %s" (Pg_error.to_string e)
     | Ok pool -> f env sw pool)
;;

module Ev = struct
  type t = { id : string }

  let kind (_ : t) = "order_placed"
  let kinds = [ "order_placed" ]
  let encode (t : t) = t.id
end

module Other = struct
  type t = { id : string }

  let kind (_ : t) = "not_declared"
  let kinds = [ "order_placed" ]
  let encode (t : t) = t.id
end

module Outbox = Sol_outbox.Make (Ev)

module Email = struct
  type t = { id : string }

  let workspace = "test"
  let kind (_ : t) = "send_email"
  let kinds = [ "send_email" ]
  let encode (t : t) = t.id
  let decode s = Ok { id = s }
  let handle (_ : t) = Ok ()
end

module Jobs = Sol_jobs.Make (Email)
module Strays = Sol_outbox.Make (Other)

let publish_in_transaction pool ~key ~ord event =
  match Pg_db.transaction pool (fun tx -> Outbox.publish tx ~key ~ord event) with
  | Ok () -> ()
  | Error e -> Alcotest.failf "publish: %s" (Pg_error.to_string e)
;;

let pending pool =
  match Sol_outbox.For_testing.pending pool () with
  | Ok rows -> rows
  | Error e -> Alcotest.failf "pending: %s" (Pg_error.to_string e)
;;

let test_state_and_intent_commit_together () =
  with_pool (fun _env _sw pool ->
    List.iter (exec_sql pool) ddl;
    (match
       Pg_db.transaction pool (fun tx ->
         let* () = Outbox.publish tx ~key:"k1" ~ord:1L { Ev.id = "e1" } in
         Error (Pg_error.Query_error "the domain change failed"))
     with
     | Ok () -> Alcotest.fail "a rolled-back transaction reported success"
     | Error _ -> ());
    Alcotest.(check (list (pair string int64)))
      "nothing survived the rollback"
      []
      (pending pool);
    publish_in_transaction pool ~key:"k1" ~ord:1L { Ev.id = "e1" };
    Alcotest.(check (list (pair string int64)))
      "the intent survived the commit"
      [ "k1", 1L ]
      (pending pool))
;;

let test_undeclared_kind_is_refused () =
  with_pool (fun _env _sw pool ->
    List.iter (exec_sql pool) ddl;
    (match
       Pg_db.transaction pool (fun tx ->
         Strays.publish tx ~key:"k1" ~ord:1L { Other.id = "e1" })
     with
     | Ok () -> Alcotest.fail "a kind nothing publishes was enqueued"
     | Error _ -> ());
    Alcotest.(check (list (pair string int64))) "nothing was written" [] (pending pool))
;;

let relay_until_drained env sw pool ~publish =
  let stop, stop_r = Eio.Promise.create () in
  let recorded = ref [] in
  let recording p =
    recorded := p :: !recorded;
    publish p
  in
  Eio.Fiber.fork ~sw (fun () ->
    ignore (Outbox.relay ~env ~pool ~publish:recording ~poll_interval_s:0.01 ~stop ()));
  let deadline = Unix.gettimeofday () +. 5.0 in
  let rec wait () =
    if Sol_outbox.For_testing.pending_count pool = Ok 0
    then ()
    else if Unix.gettimeofday () > deadline
    then Alcotest.fail "the relay did not drain within the timeout"
    else (
      Eio.Time.sleep env#clock 0.01;
      wait ())
  in
  wait ();
  Eio.Promise.resolve stop_r ();
  Eio.Fiber.yield ();
  List.rev !recorded
;;

let test_per_key_order_is_not_insertion_order () =
  with_pool (fun env sw pool ->
    List.iter (exec_sql pool) ddl;
    publish_in_transaction pool ~key:"k1" ~ord:2L { Ev.id = "second" };
    publish_in_transaction pool ~key:"k2" ~ord:1L { Ev.id = "other-key" };
    publish_in_transaction pool ~key:"k1" ~ord:1L { Ev.id = "first" };
    let recorded = relay_until_drained env sw pool ~publish:(fun _ -> Ok ()) in
    let k1 =
      recorded
      |> List.filter (fun (p : Sol_outbox.publication) -> String.equal p.key "k1")
      |> List.map (fun (p : Sol_outbox.publication) -> p.ord)
    in
    Alcotest.(check (list int64))
      "a key's events are published in ordering-token order, not insertion order"
      [ 1L; 2L ]
      k1)
;;

let test_a_failed_publish_does_not_advance_the_key () =
  with_pool (fun env sw pool ->
    List.iter (exec_sql pool) ddl;
    publish_in_transaction pool ~key:"k1" ~ord:1L { Ev.id = "first" };
    publish_in_transaction pool ~key:"k1" ~ord:2L { Ev.id = "second" };
    let attempts = ref [] in
    let failing _ =
      attempts := "failed" :: !attempts;
      Error "broker unavailable"
    in
    let stop, stop_r = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      ignore (Outbox.relay ~env ~pool ~publish:failing ~poll_interval_s:0.01 ~stop ()));
    let deadline = Unix.gettimeofday () +. 2.0 in
    let rec wait_for_attempts () =
      if List.length !attempts >= 3
      then ()
      else if Unix.gettimeofday () > deadline
      then Alcotest.fail "the relay did not retry the blocked key"
      else (
        Eio.Time.sleep env#clock 0.01;
        wait_for_attempts ())
    in
    wait_for_attempts ();
    Eio.Promise.resolve stop_r ();
    Eio.Fiber.yield ();
    Alcotest.(check (list (pair string int64)))
      "both rows are still unpublished, in their original order"
      [ "k1", 1L; "k1", 2L ]
      (pending pool);
    let recorded = ref [] in
    let succeeding p =
      recorded := (p.Sol_outbox.key, p.Sol_outbox.ord) :: !recorded;
      Ok ()
    in
    ignore (relay_until_drained env sw pool ~publish:succeeding);
    Alcotest.(check (list (pair string int64)))
      "once publication succeeds the key drains in order"
      [ "k1", 1L; "k1", 2L ]
      (List.rev !recorded);
    Alcotest.(check (list (pair string int64))) "and the table is empty" [] (pending pool))
;;

let count_rows pool table =
  match
    Pg_db.find pool ((unit ->? int) (Printf.sprintf "SELECT count(*) FROM %s" table)) ()
  with
  | Ok (Some n) -> n
  | Ok None -> 0
  | Error e -> Alcotest.failf "count %s: %s" table (Pg_error.to_string e)
;;

let test_a_row_is_kept_until_the_receipt_resolves () =
  with_pool (fun env sw pool ->
    List.iter (exec_sql pool) ddl;
    publish_in_transaction pool ~key:"k1" ~ord:1L { Ev.id = "first" };
    let in_flight, in_flight_r = Eio.Promise.create () in
    let release, release_r = Eio.Promise.create () in
    let publish p =
      ignore p;
      Eio.Promise.resolve in_flight_r ();
      Eio.Promise.await release;
      Ok ()
    in
    let stop, stop_r = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      ignore (Outbox.relay ~env ~pool ~publish ~poll_interval_s:0.01 ~stop ()));
    Eio.Promise.await in_flight;
    Alcotest.(check int)
      "the row is still there while the delivery receipt is in flight"
      1
      (count_rows pool "sol_outbox");
    Eio.Promise.resolve release_r ();
    let deadline = Unix.gettimeofday () +. 5.0 in
    let rec wait () =
      if count_rows pool "sol_outbox" = 0
      then ()
      else if Unix.gettimeofday () > deadline
      then Alcotest.fail "the row was not deleted after the receipt resolved"
      else (
        Eio.Time.sleep env#clock 0.01;
        wait ())
    in
    wait ();
    Eio.Promise.resolve stop_r ();
    Eio.Fiber.yield ())
;;

let test_a_blocked_key_does_not_block_other_keys () =
  with_pool (fun env sw pool ->
    List.iter (exec_sql pool) ddl;
    publish_in_transaction pool ~key:"blocked" ~ord:1L { Ev.id = "b1" };
    publish_in_transaction pool ~key:"healthy" ~ord:1L { Ev.id = "h1" };
    let publish (p : Sol_outbox.publication) =
      if String.equal p.key "blocked" then Error "broker unavailable" else Ok ()
    in
    let stop, stop_r = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      ignore (Outbox.relay ~env ~pool ~publish ~poll_interval_s:0.01 ~stop ()));
    let deadline = Unix.gettimeofday () +. 5.0 in
    let rec wait () =
      if pending pool = [ "blocked", 1L ]
      then ()
      else if Unix.gettimeofday () > deadline
      then
        Alcotest.failf
          "the healthy key did not drain past the blocked one: %s"
          (pending pool
           |> List.map (fun (k, o) -> Printf.sprintf "%s@%Ld" k o)
           |> String.concat ", ")
      else (
        Eio.Time.sleep env#clock 0.01;
        wait ())
    in
    wait ();
    Eio.Promise.resolve stop_r ();
    Eio.Fiber.yield ())
;;

let test_the_outbox_and_jobs_share_one_transaction () =
  with_pool (fun _env _sw pool ->
    List.iter (exec_sql pool) ddl;
    List.iter (exec_sql pool) jobs_ddl;
    (match
       Pg_db.transaction pool (fun tx ->
         let* () = Outbox.publish tx ~key:"k1" ~ord:1L { Ev.id = "e1" } in
         let* () = Jobs.enqueue tx ~dedupe_key:"e1" { Email.id = "e1" } in
         Error (Pg_error.Query_error "the domain change failed"))
     with
     | Ok () -> Alcotest.fail "a rolled-back transaction reported success"
     | Error _ -> ());
    Alcotest.(check int)
      "no event intent survived the rollback"
      0
      (count_rows pool "sol_outbox");
    Alcotest.(check int) "no job survived the rollback" 0 (count_rows pool "sol_jobs");
    (match
       Pg_db.transaction pool (fun tx ->
         let* () = Outbox.publish tx ~key:"k1" ~ord:1L { Ev.id = "e1" } in
         Jobs.enqueue tx ~dedupe_key:"e1" { Email.id = "e1" })
     with
     | Ok () -> ()
     | Error e -> Alcotest.failf "commit: %s" (Pg_error.to_string e));
    Alcotest.(check int) "the event intent committed" 1 (count_rows pool "sol_outbox");
    Alcotest.(check int) "the job committed with it" 1 (count_rows pool "sol_jobs"))
;;

let () =
  Alcotest.run
    "sol_outbox"
    [ ( "atomicity"
      , [ Alcotest.test_case
            "state and intent commit together"
            `Quick
            test_state_and_intent_commit_together
        ; Alcotest.test_case
            "an undeclared kind is refused"
            `Quick
            test_undeclared_kind_is_refused
        ] )
    ; ( "relay"
      , [ Alcotest.test_case
            "per-key order is the ordering token, not insertion order"
            `Quick
            test_per_key_order_is_not_insertion_order
        ; Alcotest.test_case
            "a failed publish does not advance the key"
            `Quick
            test_a_failed_publish_does_not_advance_the_key
        ; Alcotest.test_case
            "a row is kept until the receipt resolves"
            `Quick
            test_a_row_is_kept_until_the_receipt_resolves
        ; Alcotest.test_case
            "a blocked key does not block other keys"
            `Quick
            test_a_blocked_key_does_not_block_other_keys
        ] )
    ; ( "composition"
      , [ Alcotest.test_case
            "the outbox and sol-jobs share one transaction"
            `Quick
            test_the_outbox_and_jobs_share_one_transaction
        ] )
    ]
;;
