let check_bool msg expected actual = Alcotest.(check bool) msg expected actual
let check_string msg expected actual = Alcotest.(check string) msg expected actual

let aws_config : Sol_cli_installation.installation_config =
  { state_bucket = "sol-state-test"
  ; state_prefix = "sol/terraform.tfstate"
  ; region = "eu-west-1"
  ; lock_table = Some "sol-lock-test"
  ; provisioning_identity = Some "sol-provisioner"
  ; cluster_access_identity = Some "sol-cluster-access"
  ; deploy_identity = Some "sol-deploy"
  ; publisher_identity = Some "sol-publisher"
  ; operator_identity = Some "sol-operator"
  ; zone_domain = Some "qual-aws.example.test"
  ; project_id = None
  }
;;

let gcp_config : Sol_cli_installation.installation_config =
  { aws_config with
    lock_table = None
  ; publisher_identity = None
  ; zone_domain = Some "qual-gcp.example.test"
  ; project_id = Some "sol-project"
  }
;;

let probe_prerequisites provider config =
  Sol_cli_provider_capabilities.installation_probes provider config
  |> List.map Sol_cli_installation.probe_prerequisite
;;

let test_probe_coverage () =
  List.iter
    (fun (name, provider, config) ->
       let expected = Sol_cli_provider_capabilities.installation_prerequisites provider in
       let actual = probe_prerequisites provider config in
       Alcotest.(check (list string))
         (name ^ ": every prerequisite is probed exactly once")
         (List.map Sol_cli_installation.prerequisite_label expected)
         (List.map Sol_cli_installation.prerequisite_label actual);
       let sorted = List.sort compare actual in
       let unique = List.sort_uniq compare actual in
       Alcotest.(check int)
         (name ^ ": no duplicate probes")
         (List.length sorted)
         (List.length unique))
    [ "aws", Sol_cli_provider.Aws, aws_config; "gcp", Sol_cli_provider.Gcp, gcp_config ]
;;

let test_provider_sets_are_not_the_same_shape () =
  let aws =
    Sol_cli_provider_capabilities.installation_prerequisites Sol_cli_provider.Aws
  in
  let gcp =
    Sol_cli_provider_capabilities.installation_prerequisites Sol_cli_provider.Gcp
  in
  check_bool
    "the AWS root declares a lock table"
    true
    (List.mem Sol_cli_installation.State_lock aws);
  check_bool
    "the GCP root does not (its state bucket locks itself)"
    false
    (List.mem Sol_cli_installation.State_lock gcp);
  check_bool
    "the AWS root declares a publisher policy"
    true
    (List.mem Sol_cli_installation.Publisher_identity aws);
  check_bool
    "the GCP root does not"
    false
    (List.mem Sol_cli_installation.Publisher_identity gcp);
  check_bool
    "both name the identities the installation contains"
    true
    (List.mem Sol_cli_installation.Provisioning_identity gcp
     && List.mem Sol_cli_installation.Cluster_access_identity gcp
     && List.mem Sol_cli_installation.Deploy_identity gcp
     && List.mem Sol_cli_installation.Operator_identity gcp)
;;

let test_unobservable_is_never_established () =
  let probes =
    [ Sol_cli_installation.Inspect
        { prerequisite = Sol_cli_installation.State_backend
        ; argv = [ "aws"; "s3api"; "head-bucket" ]
        ; classify = (fun _ -> Sol_cli_installation.Established)
        }
    ]
  in
  match Sol_cli_installation.observe ~run:(fun _ -> None) probes with
  | [ (_, verdict) ] ->
    (match verdict with
     | Sol_cli_installation.Unknown reason ->
       check_bool "the refusal says why" true (String.length reason > 0)
     | Sol_cli_installation.Established ->
       Alcotest.fail "a probe that could not run was reported Established"
     | Sol_cli_installation.Unmet reason ->
       Alcotest.fail ("expected Unknown, got Unmet: " ^ reason))
  | _ -> Alcotest.fail "expected one verdict"
;;

let test_observation_drives_the_verdict () =
  let probes =
    [ Sol_cli_installation.Inspect
        { prerequisite = Sol_cli_installation.State_backend
        ; argv = [ "aws"; "s3api"; "head-bucket" ]
        ; classify =
            (function
              | Some _ -> Sol_cli_installation.Established
              | None -> Sol_cli_installation.Unknown "not run")
        }
    ]
  in
  match Sol_cli_installation.observe ~run:(fun _ -> Some "ok") probes with
  | [ (_, Sol_cli_installation.Established) ] -> ()
  | _ -> Alcotest.fail "an observed resource should be Established"
;;

let test_missing_configuration_is_unmet () =
  let bare =
    { aws_config with
      lock_table = None
    ; provisioning_identity = None
    ; cluster_access_identity = None
    ; deploy_identity = None
    ; publisher_identity = None
    ; operator_identity = None
    ; zone_domain = None
    }
  in
  let inspected = ref [] in
  let verdicts =
    Sol_cli_provider_capabilities.installation_probes Sol_cli_provider.Aws bare
    |> Sol_cli_installation.observe ~run:(fun argv ->
      inspected := argv :: !inspected;
      Some "present")
  in
  Alcotest.(check int) "only the state backend is inspected" 1 (List.length !inspected);
  List.iter
    (fun (prerequisite, verdict) ->
       match prerequisite, verdict with
       | Sol_cli_installation.State_backend, _ ->
         check_bool "the state backend is still inspected" true true
       | _, Sol_cli_installation.Unmet reason ->
         check_bool
           (Sol_cli_installation.prerequisite_label prerequisite ^ " says what is missing")
           true
           (String.length reason > 0)
       | _, Sol_cli_installation.Unknown _ ->
         Alcotest.fail "an absent configuration value is Unmet, not UNKNOWN"
       | _, Sol_cli_installation.Established ->
         Alcotest.fail "nothing is established in an empty configuration")
    verdicts
;;

let test_all_established_fails_closed () =
  let open Sol_cli_installation in
  let ok = [ State_backend, establish; Delegated_zone, establish ] in
  check_bool "all established is Ok" true (all_established ok = Ok ());
  (match
     all_established [ State_backend, establish; State_lock, unknown "no answer" ]
   with
   | Error message ->
     check_string
       "the refusal names the prerequisite and its reason"
       "terraform state lock is UNKNOWN: no answer"
       message
   | Ok () -> Alcotest.fail "UNKNOWN must fail closed");
  match all_established [ State_backend, unmet "no bucket" ] with
  | Error message ->
    check_string
      "Unmet fails closed too"
      "terraform state backend is Unmet: no bucket"
      message
  | Ok () -> Alcotest.fail "Unmet must fail closed"
;;

let test_resolved_configuration_has_no_authority () =
  let lines = Sol_cli_installation.resolved_configuration_to_lines aws_config in
  check_bool "the resolved configuration is inspectable" true (List.length lines >= 6);
  check_bool
    "it names derived plumbing"
    true
    (List.exists (fun line -> String.contains line 'e' && String.length line > 10) lines);
  check_bool
    "it declares no authority grant"
    false
    (List.exists
       (fun line ->
          let lowered = String.lowercase_ascii line in
          List.exists
            (fun marker ->
               String.length lowered > 0
               &&
               try
                 ignore (Str.search_forward (Str.regexp_string marker) lowered 0);
                 true
               with
               | Not_found -> false)
            [ "policy"; "grant"; "accountab"; "audit" ])
       lines)
;;

let () =
  Alcotest.run
    "installation"
    [ ( "prerequisites"
      , [ Alcotest.test_case
            "every prerequisite has exactly one probe"
            `Quick
            test_probe_coverage
        ; Alcotest.test_case
            "the provider sets are not the same shape"
            `Quick
            test_provider_sets_are_not_the_same_shape
        ] )
    ; ( "verdicts"
      , [ Alcotest.test_case
            "an unobservable probe is never Established"
            `Quick
            test_unobservable_is_never_established
        ; Alcotest.test_case
            "an observation drives the verdict"
            `Quick
            test_observation_drives_the_verdict
        ; Alcotest.test_case
            "absent configuration is Unmet, not UNKNOWN"
            `Quick
            test_missing_configuration_is_unmet
        ; Alcotest.test_case
            "all_established fails closed"
            `Quick
            test_all_established_fails_closed
        ] )
    ; ( "resolved configuration"
      , [ Alcotest.test_case
            "carries plumbing and no authority"
            `Quick
            test_resolved_configuration_has_no_authority
        ] )
    ]
;;
