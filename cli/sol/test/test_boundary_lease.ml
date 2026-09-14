(* FEAT-072: boundary-lease model, pure decisions and serialization. The kubectl
   CAS path needs a live cluster and is not exercised here; everything that
   decides *what* to do with a lease is. *)

let contains re s =
  try
    ignore (Str.search_forward re s 0);
    true
  with
  | Not_found -> false
;;

let lease ?(holder = Sol_cli_boundary_lease.Deploy) ?(heartbeat_at = 1000.) () =
  let base =
    Sol_cli_boundary_lease.create
      ~boundary:"myapp"
      ~holder
      ~run_id:("run-" ^ Sol_cli_boundary_lease.holder_to_string holder)
      ~now:1000.
  in
  { base with heartbeat_at }
;;

let test_holder_round_trip () =
  Alcotest.(check bool)
    "deploy"
    true
    (Sol_cli_boundary_lease.holder_of_string "deploy" = Ok Sol_cli_boundary_lease.Deploy);
  Alcotest.(check bool)
    "rollback"
    true
    (Sol_cli_boundary_lease.holder_of_string "rollback"
     = Ok Sol_cli_boundary_lease.Rollback);
  assert (Result.is_error (Sol_cli_boundary_lease.holder_of_string "deployer"));
  Alcotest.(check string)
    "back to string"
    "deploy"
    (Sol_cli_boundary_lease.holder_to_string Sol_cli_boundary_lease.Deploy)
;;

let test_is_stale_boundary () =
  let t = lease ~heartbeat_at:1000. () in
  Alcotest.(check bool)
    "exactly at ttl is live"
    false
    (Sol_cli_boundary_lease.is_stale ~now:1100. ~ttl:100. t);
  Alcotest.(check bool)
    "past ttl is stale"
    true
    (Sol_cli_boundary_lease.is_stale ~now:1100.1 ~ttl:100. t)
;;

let test_deploy_decision () =
  Alcotest.(check bool)
    "free"
    true
    (Sol_cli_boundary_lease.deploy_decision ~now:1000. ~ttl:100. None
     = Sol_cli_boundary_lease.Proceed);
  Alcotest.(check bool)
    "stale is taken over"
    true
    (Sol_cli_boundary_lease.deploy_decision
       ~now:1000.
       ~ttl:100.
       (Some (lease ~heartbeat_at:50. ()))
     = Sol_cli_boundary_lease.Proceed);
  match
    Sol_cli_boundary_lease.deploy_decision
      ~now:1000.
      ~ttl:100.
      (Some (lease ~holder:Sol_cli_boundary_lease.Deploy ~heartbeat_at:990. ()))
  with
  | Sol_cli_boundary_lease.Refuse msg ->
    assert (contains (Str.regexp "myapp") msg);
    assert (contains (Str.regexp "deploy") msg)
  | Proceed | Request_abort _ -> Alcotest.fail "expected deploy to refuse a live holder"
;;

let test_rollback_decision () =
  Alcotest.(check bool)
    "free"
    true
    (Sol_cli_boundary_lease.rollback_decision ~now:1000. ~ttl:100. None
     = Sol_cli_boundary_lease.Proceed);
  Alcotest.(check bool)
    "stale deploy is taken over"
    true
    (Sol_cli_boundary_lease.rollback_decision
       ~now:1000.
       ~ttl:100.
       (Some (lease ~heartbeat_at:50. ()))
     = Sol_cli_boundary_lease.Proceed);
  (match
     Sol_cli_boundary_lease.rollback_decision
       ~now:1000.
       ~ttl:100.
       (Some (lease ~holder:Sol_cli_boundary_lease.Deploy ~heartbeat_at:990. ()))
   with
   | Sol_cli_boundary_lease.Request_abort msg ->
     assert (contains (Str.regexp "deploy") msg)
   | Proceed | Refuse _ -> Alcotest.fail "expected rollback to request an abort");
  match
    Sol_cli_boundary_lease.rollback_decision
      ~now:1000.
      ~ttl:100.
      (Some (lease ~holder:Sol_cli_boundary_lease.Rollback ~heartbeat_at:990. ()))
  with
  | Sol_cli_boundary_lease.Refuse msg -> assert (contains (Str.regexp "rollback") msg)
  | Proceed | Request_abort _ ->
    Alcotest.fail "expected rollback to refuse a live rollback"
;;

let test_serialization_round_trip () =
  let original =
    Sol_cli_boundary_lease.create
      ~boundary:"my-app"
      ~holder:Sol_cli_boundary_lease.Rollback
      ~run_id:"rollback-2026"
      ~now:1000.5
  in
  let original =
    Sol_cli_boundary_lease.with_abort_requested original ~reason:"deploy was slow"
  in
  let json =
    Yojson.Safe.from_string (Sol_cli_boundary_lease.to_configmap_json original)
  in
  match Sol_cli_boundary_lease.of_configmap_item json with
  | Error msg -> Alcotest.fail msg
  | Ok (parsed, resource_version) ->
    Alcotest.(check string) "boundary" original.boundary parsed.boundary;
    Alcotest.(check bool) "holder" true (parsed.holder = original.holder);
    Alcotest.(check string) "run_id" original.run_id parsed.run_id;
    Alcotest.(check bool) "started_at" true (parsed.started_at = original.started_at);
    Alcotest.(check bool) "heartbeat_at" true (parsed.heartbeat_at = original.heartbeat_at);
    Alcotest.(check bool) "abort_requested" true parsed.abort_requested;
    Alcotest.(check (option string))
      "abort_reason"
      original.abort_reason
      parsed.abort_reason;
    Alcotest.(check string) "no resourceVersion in our own output" "" resource_version;
    Alcotest.(check string)
      "object name is sanitized"
      "sol-boundary-lease-my-app"
      (Sol_cli_boundary_lease.configmap_name ~workspace:"My_App")
;;

let test_parse_fails_closed () =
  assert (Result.is_error (Sol_cli_boundary_lease.of_configmap_item (`Assoc [])));
  assert (
    Result.is_error
      (Sol_cli_boundary_lease.of_configmap_item
         (`Assoc [ "data", `Assoc [ "holder", `String "nope"; "boundary", `String "x" ] ])));
  assert (
    Result.is_error
      (Sol_cli_boundary_lease.of_configmap_item
         (`Assoc
             [ ( "data"
               , `Assoc
                   [ "holder", `String "deploy"
                   ; "boundary", `String "x"
                   ; "started_at", `String "not-a-float"
                   ; "heartbeat_at", `String "1.0"
                   ] )
             ])))
;;

let test_make_run_id_is_prefixed () =
  let id =
    Sol_cli_boundary_lease.make_run_id
      ~holder:Sol_cli_boundary_lease.Deploy
      ~now:0.
      ~pid:42
  in
  assert (contains (Str.regexp "^deploy-") id);
  assert (contains (Str.regexp "42$") id)
;;

let () =
  Alcotest.run
    "boundary_lease"
    [ ( "model"
      , [ Alcotest.test_case "holder round trip" `Quick test_holder_round_trip
        ; Alcotest.test_case "staleness boundary" `Quick test_is_stale_boundary
        ; Alcotest.test_case "run id" `Quick test_make_run_id_is_prefixed
        ] )
    ; ( "decisions"
      , [ Alcotest.test_case "deploy decision" `Quick test_deploy_decision
        ; Alcotest.test_case "rollback decision" `Quick test_rollback_decision
        ] )
    ; ( "serialization"
      , [ Alcotest.test_case "round trip" `Quick test_serialization_round_trip
        ; Alcotest.test_case "fails closed" `Quick test_parse_fails_closed
        ] )
    ]
;;
