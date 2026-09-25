(* FEAT-050: immutable artifact reference parsing and resolution. *)

let check_bool = Alcotest.(check bool)
let check_str = Alcotest.(check string)
let digest hex = "registry.example.com/pluto/charge-svc@sha256:" ^ hex
let valid_digest = digest (String.make 64 'a')

let test_is_digest_accepts_well_formed () =
  check_bool "valid lowercase digest" true (Sol_cli_image_ref.is_digest valid_digest);
  check_bool
    "registry with port and path"
    true
    (Sol_cli_image_ref.is_digest ("localhost:5000/ws/svc@sha256:" ^ String.make 64 '0'))
;;

let test_is_digest_rejects_malformed () =
  check_bool "plain tag" false (Sol_cli_image_ref.is_digest "repo:tag");
  check_bool
    "empty repo"
    false
    (Sol_cli_image_ref.is_digest ("@sha256:" ^ String.make 64 'a'));
  check_bool "short hex" false (Sol_cli_image_ref.is_digest (digest (String.make 63 'a')));
  check_bool "too long" false (Sol_cli_image_ref.is_digest (digest (String.make 65 'a')));
  check_bool
    "uppercase hex rejected"
    false
    (Sol_cli_image_ref.is_digest (digest (String.make 64 'A')));
  check_bool
    "wrong algorithm"
    false
    (Sol_cli_image_ref.is_digest
       ("registry.example.com/pluto/charge-svc@sha512:" ^ String.make 64 'a'))
;;

let test_split_flag_value () =
  let name, ref = Sol_cli_image_ref.split_flag_value ("charge_svc=" ^ valid_digest) in
  check_bool "service prefix parsed" true (name = Some "charge_svc");
  check_str "reference preserved" valid_digest ref;
  let name, ref = Sol_cli_image_ref.split_flag_value valid_digest in
  check_bool "bare reference has no service" true (name = None);
  check_str "bare reference preserved" valid_digest ref
;;

let resolve = Sol_cli_image_ref.resolve

let test_resolve_named () =
  match resolve ~service_names:[ "a"; "b" ] [ Some "b", valid_digest ] with
  | Ok [ ("b", ref) ] -> check_str "resolved" valid_digest ref
  | Ok _ -> Alcotest.fail "expected a single resolved reference"
  | Error msg -> Alcotest.fail msg
;;

let test_resolve_bare_requires_one_service () =
  (match resolve ~service_names:[ "only" ] [ None, valid_digest ] with
   | Ok [ ("only", _) ] -> ()
   | Ok _ -> Alcotest.fail "expected the only service to be resolved"
   | Error msg -> Alcotest.fail msg);
  match resolve ~service_names:[ "a"; "b" ] [ None, valid_digest ] with
  | Ok _ -> Alcotest.fail "an ambiguous bare reference must fail"
  | Error msg -> check_bool "names the ambiguity" true (String.length msg > 0)
;;

let test_resolve_rejects_unknown_service () =
  match resolve ~service_names:[ "a" ] [ Some "typo", valid_digest ] with
  | Ok _ -> Alcotest.fail "an unknown service must fail"
  | Error msg -> check_bool "explains the failure" true (String.length msg > 0)
;;

let test_resolve_rejects_duplicates () =
  match
    resolve ~service_names:[ "a" ] [ Some "a", valid_digest; Some "a", valid_digest ]
  with
  | Ok _ -> Alcotest.fail "a duplicate service must fail"
  | Error _ -> ()
;;

let test_resolve_rejects_mutable_reference () =
  match resolve ~service_names:[ "a" ] [ Some "a", "repo:tag" ] with
  | Ok _ -> Alcotest.fail "a mutable reference must fail"
  | Error _ -> ()
;;

let test_plan_is_immutable () =
  check_bool "all digests" true (Sol_cli_image_ref.plan_is_immutable [ valid_digest ]);
  check_bool
    "one tag fails"
    false
    (Sol_cli_image_ref.plan_is_immutable [ valid_digest; "repo:tag" ]);
  check_bool "empty plan fails" false (Sol_cli_image_ref.plan_is_immutable [])
;;

let () =
  Alcotest.run
    "image_ref"
    [ ( "is_digest"
      , [ Alcotest.test_case "well formed" `Quick test_is_digest_accepts_well_formed
        ; Alcotest.test_case "malformed" `Quick test_is_digest_rejects_malformed
        ] )
    ; ( "split_flag_value"
      , [ Alcotest.test_case "service prefix" `Quick test_split_flag_value ] )
    ; ( "resolve"
      , [ Alcotest.test_case "named" `Quick test_resolve_named
        ; Alcotest.test_case
            "bare requires one service"
            `Quick
            test_resolve_bare_requires_one_service
        ; Alcotest.test_case "unknown service" `Quick test_resolve_rejects_unknown_service
        ; Alcotest.test_case "duplicates" `Quick test_resolve_rejects_duplicates
        ; Alcotest.test_case
            "mutable reference"
            `Quick
            test_resolve_rejects_mutable_reference
        ] )
    ; ( "plan_is_immutable"
      , [ Alcotest.test_case "predicate" `Quick test_plan_is_immutable ] )
    ]
;;
