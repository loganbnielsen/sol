let matches_regex re s =
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
  Windtrap.equal
    Windtrap.bool
    ~msg:"deploy"
    true
    (Sol_cli_boundary_lease.holder_of_string "deploy" = Ok Sol_cli_boundary_lease.Deploy);
  Windtrap.equal
    Windtrap.bool
    ~msg:"rollback"
    true
    (Sol_cli_boundary_lease.holder_of_string "rollback"
     = Ok Sol_cli_boundary_lease.Rollback);
  assert (Result.is_error (Sol_cli_boundary_lease.holder_of_string "deployer"));
  Windtrap.equal
    Windtrap.string
    ~msg:"back to string"
    "deploy"
    (Sol_cli_boundary_lease.holder_to_string Sol_cli_boundary_lease.Deploy)
;;

let test_is_stale_boundary () =
  let t = lease ~heartbeat_at:1000. () in
  Windtrap.equal
    Windtrap.bool
    ~msg:"exactly at ttl is live"
    false
    (Sol_cli_boundary_lease.is_stale ~now:1100. ~ttl:100. t);
  Windtrap.equal
    Windtrap.bool
    ~msg:"past ttl is stale"
    true
    (Sol_cli_boundary_lease.is_stale ~now:1100.1 ~ttl:100. t)
;;

let test_deploy_decision () =
  Windtrap.equal
    Windtrap.bool
    ~msg:"free"
    true
    (Sol_cli_boundary_lease.deploy_decision ~now:1000. ~ttl:100. None
     = Sol_cli_boundary_lease.Proceed);
  Windtrap.equal
    Windtrap.bool
    ~msg:"stale is taken over"
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
    assert (matches_regex (Str.regexp "myapp") msg);
    assert (matches_regex (Str.regexp "deploy") msg)
  | Proceed | Request_abort _ -> Windtrap.fail "expected deploy to refuse a live holder"
;;

let test_rollback_decision () =
  Windtrap.equal
    Windtrap.bool
    ~msg:"free"
    true
    (Sol_cli_boundary_lease.rollback_decision ~now:1000. ~ttl:100. None
     = Sol_cli_boundary_lease.Proceed);
  Windtrap.equal
    Windtrap.bool
    ~msg:"stale deploy is taken over"
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
     assert (matches_regex (Str.regexp "deploy") msg)
   | Proceed | Refuse _ -> Windtrap.fail "expected rollback to request an abort");
  match
    Sol_cli_boundary_lease.rollback_decision
      ~now:1000.
      ~ttl:100.
      (Some (lease ~holder:Sol_cli_boundary_lease.Rollback ~heartbeat_at:990. ()))
  with
  | Sol_cli_boundary_lease.Refuse msg ->
    assert (matches_regex (Str.regexp "rollback") msg)
  | Proceed | Request_abort _ ->
    Windtrap.fail "expected rollback to refuse a live rollback"
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
  | Error msg -> Windtrap.fail msg
  | Ok (parsed, resource_version) ->
    Windtrap.equal Windtrap.string ~msg:"boundary" original.boundary parsed.boundary;
    Windtrap.equal Windtrap.bool ~msg:"holder" true (parsed.holder = original.holder);
    Windtrap.equal Windtrap.string ~msg:"run_id" original.run_id parsed.run_id;
    Windtrap.equal
      Windtrap.bool
      ~msg:"started_at"
      true
      (parsed.started_at = original.started_at);
    Windtrap.equal
      Windtrap.bool
      ~msg:"heartbeat_at"
      true
      (parsed.heartbeat_at = original.heartbeat_at);
    Windtrap.equal Windtrap.bool ~msg:"abort_requested" true parsed.abort_requested;
    Windtrap.equal
      (Windtrap.option Windtrap.string)
      ~msg:"abort_reason"
      original.abort_reason
      parsed.abort_reason;
    Windtrap.equal
      Windtrap.string
      ~msg:"no resourceVersion in our own output"
      ""
      resource_version;
    Windtrap.equal
      Windtrap.string
      ~msg:"object name is sanitized"
      "sol-boundary-lease-my-app"
      (Sol_cli_boundary_lease.configmap_name ~workspace:"My_App")
;;

let test_replace_carries_resource_version () =
  let lease =
    Sol_cli_boundary_lease.create ~boundary:"myapp" ~holder:Deploy ~run_id:"r" ~now:1.
  in
  let json resource_version =
    Yojson.Safe.from_string
      (Sol_cli_boundary_lease.to_configmap_json ~resource_version lease)
  in
  (match Sol_cli_boundary_lease.of_configmap_item (json "42") with
   | Ok (_, resource_version) ->
     Windtrap.equal Windtrap.string ~msg:"resourceVersion carried" "42" resource_version
   | Error msg -> Windtrap.fail msg);
  match Sol_cli_boundary_lease.of_configmap_item (json "") with
  | Ok (_, resource_version) ->
    Windtrap.equal Windtrap.string ~msg:"an empty version is omitted" "" resource_version
  | Error msg -> Windtrap.fail msg
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
  assert (matches_regex (Str.regexp "^deploy-") id);
  assert (matches_regex (Str.regexp "42$") id)
;;

let%test "model: holder round trip" = test_holder_round_trip ()
let%test "model: staleness boundary" = test_is_stale_boundary ()
let%test "model: run id" = test_make_run_id_is_prefixed ()
let%test "decisions: deploy decision" = test_deploy_decision ()
let%test "decisions: rollback decision" = test_rollback_decision ()
let%test "serialization: round trip" = test_serialization_round_trip ()

let%test "serialization: replace carries resourceVersion" =
  test_replace_carries_resource_version ()
;;

let%test "serialization: fails closed" = test_parse_fails_closed ()
