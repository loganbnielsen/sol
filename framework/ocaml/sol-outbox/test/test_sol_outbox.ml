open Caqti_request.Infix
open Caqti_type
open Result.Syntax

let postgres_url () =
  match Array.to_list Sys.argv with
  | _ :: url :: _ when String.trim url <> "" -> Some url
  | _ -> None
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
    \  workspace TEXT NOT NULL,\n\
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
  ; "CREATE UNIQUE INDEX sol_jobs_dedupe_idx ON sol_jobs (workspace, kind, dedupe_key) \
     WHERE dedupe_key IS NOT NULL"
  ]
;;

let exec_sql pool sql =
  match Pg_db.exec pool ((unit ->. unit) sql) () with
  | Ok () -> ()
  | Error e -> Windtrap.failf "%s: %s" sql (Pg_error.to_string e)
;;

let with_pool f =
  match postgres_url () with
  | None ->
    Windtrap.fail
      "no Postgres address: the runtest-integration alias in \
       framework/ocaml/sol-outbox/test/dune pins one, and a run without a database is \
       not a passing run"
  | Some url ->
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    (match Pg_db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) () with
     | Error e -> Windtrap.failf "pool: %s" (Pg_error.to_string e)
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
  | Error e -> Windtrap.failf "publish: %s" (Pg_error.to_string e)
;;

let pending pool =
  match Sol_outbox.For_testing.pending pool () with
  | Ok rows -> rows
  | Error e -> Windtrap.failf "pending: %s" (Pg_error.to_string e)
;;

let test_state_and_intent_commit_together () =
  with_pool (fun _env _sw pool ->
    List.iter (exec_sql pool) ddl;
    (match
       Pg_db.transaction pool (fun tx ->
         let* () = Outbox.publish tx ~key:"k1" ~ord:1L { Ev.id = "e1" } in
         Error (Pg_error.Query_error "the domain change failed"))
     with
     | Ok () -> Windtrap.fail "a rolled-back transaction reported success"
     | Error _ -> ());
    Windtrap.equal
      (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.int64))
      ~msg:"nothing survived the rollback"
      []
      (pending pool);
    publish_in_transaction pool ~key:"k1" ~ord:1L { Ev.id = "e1" };
    Windtrap.equal
      (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.int64))
      ~msg:"the intent survived the commit"
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
     | Ok () -> Windtrap.fail "a kind nothing publishes was enqueued"
     | Error _ -> ());
    Windtrap.equal
      (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.int64))
      ~msg:"nothing was written"
      []
      (pending pool))
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
    then Windtrap.fail "the relay did not drain within the timeout"
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
    Windtrap.equal
      (Windtrap.list Windtrap.int64)
      ~msg:"a key's events are published in ordering-token order, not insertion order"
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
      then Windtrap.fail "the relay did not retry the blocked key"
      else (
        Eio.Time.sleep env#clock 0.01;
        wait_for_attempts ())
    in
    wait_for_attempts ();
    Eio.Promise.resolve stop_r ();
    Eio.Fiber.yield ();
    Windtrap.equal
      (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.int64))
      ~msg:"both rows are still unpublished, in their original order"
      [ "k1", 1L; "k1", 2L ]
      (pending pool);
    let recorded = ref [] in
    let succeeding p =
      recorded := (p.Sol_outbox.key, p.Sol_outbox.ord) :: !recorded;
      Ok ()
    in
    ignore (relay_until_drained env sw pool ~publish:succeeding);
    Windtrap.equal
      (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.int64))
      ~msg:"once publication succeeds the key drains in order"
      [ "k1", 1L; "k1", 2L ]
      (List.rev !recorded);
    Windtrap.equal
      (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.int64))
      ~msg:"and the table is empty"
      []
      (pending pool))
;;

let count_rows pool table =
  match
    Pg_db.find pool ((unit ->? int) (Printf.sprintf "SELECT count(*) FROM %s" table)) ()
  with
  | Ok (Some n) -> n
  | Ok None -> 0
  | Error e -> Windtrap.failf "count %s: %s" table (Pg_error.to_string e)
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
    Windtrap.equal
      Windtrap.int
      ~msg:"the row is still there while the delivery receipt is in flight"
      1
      (count_rows pool "sol_outbox");
    Eio.Promise.resolve release_r ();
    let deadline = Unix.gettimeofday () +. 5.0 in
    let rec wait () =
      if count_rows pool "sol_outbox" = 0
      then ()
      else if Unix.gettimeofday () > deadline
      then Windtrap.fail "the row was not deleted after the receipt resolved"
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
        Windtrap.failf
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
     | Ok () -> Windtrap.fail "a rolled-back transaction reported success"
     | Error _ -> ());
    Windtrap.equal
      Windtrap.int
      ~msg:"no event intent survived the rollback"
      0
      (count_rows pool "sol_outbox");
    Windtrap.equal
      Windtrap.int
      ~msg:"no job survived the rollback"
      0
      (count_rows pool "sol_jobs");
    (match
       Pg_db.transaction pool (fun tx ->
         let* () = Outbox.publish tx ~key:"k1" ~ord:1L { Ev.id = "e1" } in
         Jobs.enqueue tx ~dedupe_key:"e1" { Email.id = "e1" })
     with
     | Ok () -> ()
     | Error e -> Windtrap.failf "commit: %s" (Pg_error.to_string e));
    Windtrap.equal
      Windtrap.int
      ~msg:"the event intent committed"
      1
      (count_rows pool "sol_outbox");
    Windtrap.equal
      Windtrap.int
      ~msg:"the job committed with it"
      1
      (count_rows pool "sol_jobs"))
;;

let () =
  Windtrap.run
    ~argv:[||]
    "sol_outbox"
    [ Windtrap.group
        "atomicity"
        [ Windtrap.test
            "state and intent commit together"
            test_state_and_intent_commit_together
        ; Windtrap.test "an undeclared kind is refused" test_undeclared_kind_is_refused
        ]
    ; Windtrap.group
        "relay"
        [ Windtrap.test
            "per-key order is the ordering token, not insertion order"
            test_per_key_order_is_not_insertion_order
        ; Windtrap.test
            "a failed publish does not advance the key"
            test_a_failed_publish_does_not_advance_the_key
        ; Windtrap.test
            "a row is kept until the receipt resolves"
            test_a_row_is_kept_until_the_receipt_resolves
        ; Windtrap.test
            "a blocked key does not block other keys"
            test_a_blocked_key_does_not_block_other_keys
        ]
    ; Windtrap.group
        "composition"
        [ Windtrap.test
            "the outbox and sol-jobs share one transaction"
            test_the_outbox_and_jobs_share_one_transaction
        ]
    ]
;;
