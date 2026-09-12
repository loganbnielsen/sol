(* FEAT-061: the scope vocabulary.

   Resolution is tested against [named] values rather than discovered services,
   so these cases describe the *rules* (a name resolves, an unknown name fails
   closed and says what exists) instead of the repo's current contents. *)

open Sol_cli_deployment_scope

let unit_ ~domain ~name ~kind = { domain; name; kind }

let units () =
  [ unit_ ~domain:"payments" ~name:"charge_svc" ~kind:Service
  ; unit_ ~domain:"payments" ~name:"settle_worker" ~kind:Worker
  ; unit_ ~domain:"comms" ~name:"notify_fn" ~kind:Function
  ]
;;

let contains ~needle haystack =
  let n = String.length needle
  and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  n = 0 || go 0
;;

(* Requests are compared through their user-facing spelling: it is what a person
   types and what an error quotes, so a test that reads in those terms is
   checking the thing that matters rather than the constructor names. *)
let request_to_string = function
  | Whole_workspace -> "workspace"
  | Whole_domain domain -> domain
  | Unit_named (domain, name) -> Printf.sprintf "%s/%s" domain name
;;

let parsed value = Result.map request_to_string (parse_request value)

(* A test that expected matches asserts it: the exhaustive match is the compiler
   making sure emptiness is considered rather than overlooked. *)
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
  (* A three-segment value is a *path*, which is what the positional argument is
     for. Accepting it here would make the escape hatch and the scope the same
     thing. *)
  match parse_request (Some "app/payments/charge_svc") with
  | Ok _ -> Alcotest.fail "a path must not parse as a scope"
  | Error message ->
    assert (contains ~needle:"payments/charge_svc" message);
    assert (contains ~needle:"got" message)
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
  (* The user says a name; discovery says what it is. Getting the kind from the
     request would mean asking the user to remember the filesystem. *)
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
    assert (contains ~needle:"logistics" message);
    assert (contains ~needle:"comms" message);
    assert (contains ~needle:"payments" message)
;;

let test_unknown_unit_names_what_exists () =
  match resolve (Unit_named ("payments", "refund_svc")) (units ()) with
  | Ok _ -> Alcotest.fail "an unknown unit must not resolve"
  | Error message ->
    assert (contains ~needle:"payments/refund_svc" message);
    (* What it asked for, and what is there: the whole point of failing closed. *)
    assert (contains ~needle:"payments/charge_svc" message);
    assert (contains ~needle:"payments/settle_worker" message)
;;

let test_unit_in_unknown_domain_lists_domains () =
  match resolve (Unit_named ("logistics", "ship_worker")) (units ()) with
  | Ok _ -> Alcotest.fail "must not resolve"
  | Error message ->
    assert (contains ~needle:"logistics/ship_worker" message);
    assert (contains ~needle:"comms" message)
;;

let test_kind_mapping () =
  Alcotest.(check string) "svc" "service" (kind_to_string (kind_of_primitive Svc));
  Alcotest.(check string) "worker" "worker" (kind_to_string (kind_of_primitive Worker));
  Alcotest.(check string) "fn" "function" (kind_to_string (kind_of_primitive Fn))
;;

let test_hyphenated_spelling_resolves_the_same_unit () =
  (* `settle-worker` is what a user sees in the cluster; `settle_worker` is the
     repository name and stays canonical. Neither spelling becomes a second
     identity. *)
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

let () =
  Alcotest.run
    "deployment_scope"
    [ ( "deployment_scope"
      , [ Alcotest.test_case
            "absent means the whole workspace"
            `Quick
            test_absent_is_the_whole_workspace
        ; Alcotest.test_case
            "parses a domain and a unit"
            `Quick
            test_parses_domain_and_unit
        ; Alcotest.test_case
            "rejects a path"
            `Quick
            test_rejects_what_it_cannot_understand
        ; Alcotest.test_case
            "workspace selects everything"
            `Quick
            test_workspace_selects_everything
        ; Alcotest.test_case
            "domain selects its units"
            `Quick
            test_domain_selects_its_units
        ; Alcotest.test_case
            "kind comes from discovery"
            `Quick
            test_unit_takes_its_kind_from_discovery
        ; Alcotest.test_case
            "unknown domain fails closed"
            `Quick
            test_unknown_domain_fails_closed
        ; Alcotest.test_case
            "unknown unit lists what exists"
            `Quick
            test_unknown_unit_names_what_exists
        ; Alcotest.test_case
            "unit in unknown domain lists domains"
            `Quick
            test_unit_in_unknown_domain_lists_domains
        ; Alcotest.test_case "primitive maps to kind" `Quick test_kind_mapping
        ; Alcotest.test_case
            "hyphenated spelling resolves the same unit"
            `Quick
            test_hyphenated_spelling_resolves_the_same_unit
        ; Alcotest.test_case
            "nothing discovered is Empty, not Selected"
            `Quick
            test_nothing_discovered_is_empty_not_selected
        ] )
    ]
;;
