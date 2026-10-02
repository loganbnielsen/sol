open Sol_cli_deployment_scope

let unit_ ~domain ~name ~kind = { domain; name; kind }

let units () =
  [ unit_ ~domain:"payments" ~name:"charge_svc" ~kind:Service
  ; unit_ ~domain:"payments" ~name:"settle_worker" ~kind:Worker
  ; unit_ ~domain:"comms" ~name:"notify_fn" ~kind:Function
  ]
;;

let request_to_string = function
  | Whole_workspace -> "workspace"
  | Whole_domain domain -> domain
  | Unit_named (domain, name) -> Printf.sprintf "%s/%s" domain name
;;

let parsed value = Result.map request_to_string (parse_request value)

let expect_selected what = function
  | Selected selected -> selected
  | Empty -> Alcotest.fail (what ^ ": expected a non-empty selection, got Empty")
;;

let test_absent_is_the_whole_workspace () =
  Alcotest.(check (result string string)) "absent" (Ok "workspace") (parsed None);
  Alcotest.(check (result string string)) "blank" (Ok "workspace") (parsed (Some "   "))
;;

let test_parses_domain_and_unit () =
  Alcotest.(check (result string string))
    "domain"
    (Ok "payments")
    (parsed (Some "payments"));
  Alcotest.(check (result string string))
    "unit"
    (Ok "payments/charge_svc")
    (parsed (Some "payments/charge_svc"))
;;

let test_rejects_what_it_cannot_understand () =
  match parse_request (Some "app/payments/charge_svc") with
  | Ok _ -> Alcotest.fail "a path must not parse as a scope"
  | Error message ->
    assert (Sol_cli_string.contains ~needle:"payments/charge_svc" message);
    assert (Sol_cli_string.contains ~needle:"got" message)
;;

let test_workspace_selects_everything () =
  match resolve Whole_workspace (units ()) with
  | Error message -> Alcotest.fail message
  | Ok (scope, selection) ->
    let selected = expect_selected "selection" selection in
    Alcotest.(check string) "scope" "workspace" (to_string scope);
    Alcotest.(check int) "everything" 3 (List.length selected)
;;

let test_domain_selects_its_units () =
  match resolve (Whole_domain "payments") (units ()) with
  | Error message -> Alcotest.fail message
  | Ok (scope, selection) ->
    let selected = expect_selected "selection" selection in
    Alcotest.(check string) "scope" "payments" (to_string scope);
    Alcotest.(check (list string))
      "only payments"
      [ "payments/charge_svc"; "payments/settle_worker" ]
      (List.map (fun u -> u.domain ^ "/" ^ u.name) selected)
;;

let test_unit_takes_its_kind_from_discovery () =
  match resolve (Unit_named ("payments", "settle_worker")) (units ()) with
  | Error message -> Alcotest.fail message
  | Ok (scope, selection) ->
    let selected = expect_selected "selection" selection in
    (match scope with
     | Unit { kind = Worker; _ } -> ()
     | _ -> Alcotest.fail "expected a worker scope, resolved from discovery");
    Alcotest.(check int) "one unit" 1 (List.length selected)
;;

let test_unknown_domain_fails_closed () =
  match resolve (Whole_domain "logistics") (units ()) with
  | Ok _ -> Alcotest.fail "an unknown domain must not resolve"
  | Error message ->
    assert (Sol_cli_string.contains ~needle:"logistics" message);
    assert (Sol_cli_string.contains ~needle:"comms" message);
    assert (Sol_cli_string.contains ~needle:"payments" message)
;;

let test_unknown_unit_names_what_exists () =
  match resolve (Unit_named ("payments", "refund_svc")) (units ()) with
  | Ok _ -> Alcotest.fail "an unknown unit must not resolve"
  | Error message ->
    assert (Sol_cli_string.contains ~needle:"payments/refund_svc" message);
    assert (Sol_cli_string.contains ~needle:"payments/charge_svc" message);
    assert (Sol_cli_string.contains ~needle:"payments/settle_worker" message)
;;

let test_unit_in_unknown_domain_lists_domains () =
  match resolve (Unit_named ("logistics", "ship_worker")) (units ()) with
  | Ok _ -> Alcotest.fail "must not resolve"
  | Error message ->
    assert (Sol_cli_string.contains ~needle:"logistics/ship_worker" message);
    assert (Sol_cli_string.contains ~needle:"comms" message)
;;

let test_kind_mapping () =
  Alcotest.(check string) "svc" "service" (kind_to_string (kind_of_primitive Svc));
  Alcotest.(check string) "worker" "worker" (kind_to_string (kind_of_primitive Worker));
  Alcotest.(check string) "fn" "function" (kind_to_string (kind_of_primitive Fn))
;;

let test_hyphenated_spelling_resolves_the_same_unit () =
  match resolve (Unit_named ("payments", "settle-worker")) (units ()) with
  | Error message -> Alcotest.fail message
  | Ok (scope, Selected [ unit ]) ->
    Alcotest.(check string) "canonical name" "settle_worker" unit.name;
    Alcotest.(check string) "canonical span" "payments/settle_worker" (to_string scope)
  | Ok _ -> Alcotest.fail "expected exactly one unit"
;;

let test_nothing_discovered_is_empty_not_selected () =
  match resolve Whole_workspace [] with
  | Error message -> Alcotest.fail message
  | Ok (_, Empty) -> ()
  | Ok (_, Selected _) -> Alcotest.fail "an empty workspace cannot be a selection"
;;

let services () =
  [ { Sol_cli_manifest.domain = "payments"
    ; name = "charge_svc"
    ; primitive = Sol_cli_manifest.Svc
    ; dir = "app/payments/charge_svc"
    }
  ; { Sol_cli_manifest.domain = "payments"
    ; name = "settle_worker"
    ; primitive = Sol_cli_manifest.Worker
    ; dir = "app/payments/settle_worker"
    }
  ; { Sol_cli_manifest.domain = "comms"
    ; name = "notify_fn"
    ; primitive = Sol_cli_manifest.Fn
    ; dir = "app/comms/notify_fn"
    }
  ]
;;

let service_names selected =
  selected.Sol_cli_workload_selection.services
  |> List.map (fun s -> s.Sol_cli_manifest.domain ^ "/" ^ s.Sol_cli_manifest.name)
;;

let test_bridge_carries_requested_scope_and_resolved_set () =
  match
    Sol_cli_workload_selection.resolve ~what:"--scope" (Some "payments") (services ())
  with
  | Error message -> Alcotest.fail message
  | Ok selected ->
    Alcotest.(check string)
      "requested scope"
      "payments"
      (request_to_string selected.request);
    Alcotest.(check string)
      "requested_scope field matches the request (REFAC-111)"
      "payments"
      selected.requested_scope;
    Alcotest.(check (list string))
      "resolved set"
      [ "payments/charge_svc"; "payments/settle_worker" ]
      (service_names selected)
;;

let test_bridge_unit_is_canonical () =
  match
    Sol_cli_workload_selection.resolve
      ~what:"--scope"
      (Some "payments/settle-worker")
      (services ())
  with
  | Error message -> Alcotest.fail message
  | Ok selected ->
    Alcotest.(check (list string))
      "canonical resolved name"
      [ "payments/settle_worker" ]
      (service_names selected)
;;

let test_bridge_empty_workspace () =
  match Sol_cli_workload_selection.resolve ~what:"--scope" None [] with
  | Error message -> Alcotest.fail message
  | Ok selected ->
    Alcotest.(check bool) "empty" true (Sol_cli_workload_selection.is_empty selected)
;;

let test_nonempty_refuses_empty_workspace () =
  match Sol_cli_workload_selection.resolve_nonempty ~none:"nothing here" None [] with
  | Ok _ -> Alcotest.fail "an empty selection was accepted"
  | Error message -> Alcotest.(check string) "the caller's message" "nothing here" message
;;

let test_nonempty_accepts_a_selection () =
  match
    Sol_cli_workload_selection.resolve_nonempty ~none:"nothing here" None (services ())
  with
  | Error message -> Alcotest.fail message
  | Ok selected ->
    Alcotest.(check string) "whole workspace" "workspace" selected.requested_scope
;;

let test_nonempty_keeps_selector_errors () =
  match
    Sol_cli_workload_selection.resolve_nonempty
      ~none:"nothing here"
      (Some "nope")
      (services ())
  with
  | Ok _ -> Alcotest.fail "unknown domain accepted"
  | Error message ->
    Alcotest.(check bool) ("selector error: " ^ message) true (message <> "nothing here")
;;

let%test "deployment_scope: absent means the whole workspace" =
  test_absent_is_the_whole_workspace ()
;;

let%test "deployment_scope: parses a domain and a unit" = test_parses_domain_and_unit ()
let%test "deployment_scope: rejects a path" = test_rejects_what_it_cannot_understand ()

let%test "deployment_scope: workspace selects everything" =
  test_workspace_selects_everything ()
;;

let%test "deployment_scope: domain selects its units" = test_domain_selects_its_units ()

let%test "deployment_scope: kind comes from discovery" =
  test_unit_takes_its_kind_from_discovery ()
;;

let%test "deployment_scope: unknown domain fails closed" =
  test_unknown_domain_fails_closed ()
;;

let%test "deployment_scope: unknown unit lists what exists" =
  test_unknown_unit_names_what_exists ()
;;

let%test "deployment_scope: unit in unknown domain lists domains" =
  test_unit_in_unknown_domain_lists_domains ()
;;

let%test "deployment_scope: primitive maps to kind" = test_kind_mapping ()

let%test "deployment_scope: hyphenated spelling resolves the same unit" =
  test_hyphenated_spelling_resolves_the_same_unit ()
;;

let%test "deployment_scope: nothing discovered is Empty, not Selected" =
  test_nothing_discovered_is_empty_not_selected ()
;;

let%test "workload_selection: carries requested scope and resolved set" =
  test_bridge_carries_requested_scope_and_resolved_set ()
;;

let%test "workload_selection: unit resolves canonically" =
  test_bridge_unit_is_canonical ()
;;

let%test "workload_selection: empty workspace is empty" = test_bridge_empty_workspace ()

let%test "workload_selection: nonempty refuses an empty selection" =
  test_nonempty_refuses_empty_workspace ()
;;

let%test "workload_selection: nonempty accepts a selection" =
  test_nonempty_accepts_a_selection ()
;;

let%test "workload_selection: nonempty keeps selector errors" =
  test_nonempty_keeps_selector_errors ()
;;
