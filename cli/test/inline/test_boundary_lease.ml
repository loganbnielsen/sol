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
    Yojson.Safe.from_string
      (Sol_cli_boundary_lease.to_configmap_json ~resource_version:"17" original)
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
    Windtrap.equal Windtrap.string ~msg:"resourceVersion" "17" resource_version;
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
  (* Our own create output omits resourceVersion, and the cluster always returns
     one. A lease read back without it cannot be compared and swapped, so it is
     refused rather than treated as a lease with a blank version. *)
  Windtrap.equal
    Windtrap.bool
    ~msg:"an absent resourceVersion is refused"
    true
    (Result.is_error (Sol_cli_boundary_lease.of_configmap_item (json "")))
;;

let field key value data = (key, value) :: List.remove_assoc key data
let without key data = List.remove_assoc key data

let valid_lease_data =
  [ "holder", `String "deploy"
  ; "boundary", `String "myapp"
  ; "run_id", `String "run"
  ; "started_at", `String "1000.000"
  ; "heartbeat_at", `String "1000.000"
  ; "abort_requested", `String "false"
  ]
;;

let lease_configmap ?(resource_version = [ "resourceVersion", `String "7" ]) data =
  `Assoc [ "metadata", `Assoc resource_version; "data", `Assoc data ]
;;

let rejects ~names label json =
  match Sol_cli_boundary_lease.of_configmap_item json with
  | Ok _ -> Windtrap.failf "%s: a malformed lease must be rejected" label
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:(Printf.sprintf "%s: the refusal names %s" label names)
      true
      (Sol_cli_string.contains ~needle:names message)
;;

(* Malformed stored coordination state must be diagnosed as external data before
   it reaches staleness, takeover, abort or time formatting. The times in
   particular must never reach [Sol_cli_time.rfc3339], which raises on an
   unrepresentable value. *)
let test_malformed_coordination_state_is_rejected () =
  let invalid field_name value label =
    rejects
      ~names:field_name
      label
      (lease_configmap (field field_name value valid_lease_data))
  in
  invalid "started_at" (`String "nan") "a NaN started_at";
  invalid "started_at" (`String "inf") "an infinite started_at";
  invalid "heartbeat_at" (`String "-infinity") "a negative infinite heartbeat_at";
  invalid "started_at" (`String "1e300") "an unrepresentable started_at";
  invalid "run_id" (`String "") "a blank run_id";
  invalid "run_id" (`String "  ") "a whitespace-only run_id";
  invalid "abort_requested" (`String "yes") "a malformed abort_requested";
  rejects
    ~names:"run_id"
    "a missing run_id"
    (lease_configmap (without "run_id" valid_lease_data));
  rejects
    ~names:"abort_requested"
    "a missing abort_requested"
    (lease_configmap (without "abort_requested" valid_lease_data));
  rejects
    ~names:"resourceVersion"
    "a missing resourceVersion"
    (lease_configmap ~resource_version:[] valid_lease_data);
  rejects
    ~names:"resourceVersion"
    "a blank resourceVersion"
    (lease_configmap
       ~resource_version:[ "resourceVersion", `String "  " ]
       valid_lease_data);
  match Sol_cli_boundary_lease.of_configmap_item (lease_configmap valid_lease_data) with
  | Ok _ -> ()
  | Error message -> Windtrap.failf "a well-formed lease must still decode: %s" message
;;

let with_fake_kubectl_json json f =
  let dir = Filename.temp_file "sol-fake-kubectl-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let body = Filename.concat dir "lease.json" in
  Out_channel.with_open_text body (fun oc -> output_string oc json);
  let bin = Filename.concat dir "kubectl" in
  Out_channel.with_open_text bin (fun oc ->
    output_string oc (Printf.sprintf "#!/bin/sh\ncat %s\n" body));
  Unix.chmod bin 0o755;
  let old_path =
    try Sys.getenv "PATH" with
    | Not_found -> ""
  in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect ~finally:(fun () -> Unix.putenv "PATH" old_path) (fun () -> f ())
;;

(* The decoder is the gate between external coordination state and the decision
   and formatter code. A malformed object read from the cluster is a contextual
   Error, never an [Invalid_argument] from formatting a NaN time. *)
let test_fetch_rejects_malformed_external_state_without_raising () =
  with_fake_kubectl_json
    {|{"metadata":{"resourceVersion":"7"},"data":{"holder":"deploy","boundary":"myapp","run_id":"run","started_at":"nan","heartbeat_at":"1000.000","abort_requested":"true"}}|}
    (fun () ->
       match
         Sol_cli_boundary_lease.fetch
           ~ctx:Sol_cli_kube_destination.local_context
           ~workspace:"myapp"
       with
       | Ok _ -> Windtrap.fail "an external lease with a NaN time must be rejected"
       | Error message ->
         Windtrap.equal
           Windtrap.bool
           ~msg:"the refusal names the malformed field"
           true
           (Sol_cli_string.contains ~needle:"started_at" message))
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

let%test "serialization: malformed coordination state is rejected" =
  test_malformed_coordination_state_is_rejected ()
;;

let%test "fetch: malformed external state is a contextual error, not a raise" =
  test_fetch_rejects_malformed_external_state_without_raising ()
;;
