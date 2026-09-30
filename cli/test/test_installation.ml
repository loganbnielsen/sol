let check_bool msg expected actual = Alcotest.(check bool) msg expected actual
let check_string msg expected actual = Alcotest.(check string) msg expected actual

let aws_config : Sol_cli_installation.installation_config =
  { state_bucket = "sol-state-test"
  ; state_prefix = "bootstrap/aws"
  ; region = "eu-west-1"
  ; lock_table = Some "sol-lock-test"
  ; provisioning_identity = Some "sol-provisioner"
  ; cluster_access_identity = Some "sol-cluster-access"
  ; deploy_identity = Some "sol-deploy"
  ; operator_identity = Some "sol-operator"
  ; zone_domain = Some "qual-aws.example.test"
  ; project_id = None
  }
;;

let gcp_config : Sol_cli_installation.installation_config =
  { aws_config with
    state_prefix = "bootstrap/gcp"
  ; lock_table = None
  ; provisioning_identity = None
  ; cluster_access_identity = None
  ; deploy_identity = None
  ; operator_identity = None
  ; zone_domain = Some "qual-gcp.example.test"
  ; project_id = Some "sol-project"
  }
;;

let probe_prerequisites provider config =
  Sol_cli_provider_capabilities.installation_probes provider config
  |> List.map Sol_cli_installation.probe_prerequisite
;;

let aws_target : Sol_cli_config.target =
  { name = "prod/aws/us-east-1"
  ; env = "prod"
  ; provider = Sol_cli_provider.Aws
  ; region = "us-east-1"
  ; registry = None
  ; base_domain = Some "api.acme.example"
  ; cluster_issuer = None
  ; letsencrypt_email = None
  ; cluster_name = Some "acme-prod"
  ; kube_context = None
  ; kubeconfig = None
  ; terraform_var_file = None
  ; observability_backend = None
  ; destroy_retention = None
  ; alert_receiver_type = None
  ; alert_receiver_url = None
  ; alert_owner = None
  ; alert_runbook_url = None
  ; state_bucket = Some "acme-tfstate"
  ; cluster_endpoint_cidr = None
  ; node_failure_headroom_nodes = None
  ; profile = None
  ; provider_fields =
      [ ( "aws"
        , [ "state_lock_table", "acme-tflock"
          ; "provisioner_role_arn", "arn:aws:iam::111122223333:role/sol-provisioner"
          ; "cluster_access_role_arn", "arn:aws:iam::111122223333:role/sol-cluster-access"
          ; "deploy_role_arn", "arn:aws:iam::111122223333:role/sol-deploy"
          ; "operator_role_arn", "arn:aws:iam::111122223333:role/sol-operator"
          ] )
      ]
  }
;;

let gcp_target : Sol_cli_config.target =
  { aws_target with
    name = "qual/gcp/us-central1"
  ; env = "qual"
  ; provider = Sol_cli_provider.Gcp
  ; region = "us-central1"
  ; state_bucket = Some "sol-qualification-tfstate"
  ; base_domain = Some "qual-gcp.example.test"
  ; provider_fields = [ "gcp", [ "project_id", "sol-qualification" ] ]
  }
;;

let resolved_or_fail target =
  match Sol_cli_installation.of_target target with
  | Ok configuration -> configuration
  | Error message -> Alcotest.fail ("of_target refused a declared target: " ^ message)
;;

let probe_argv provider configuration prerequisite =
  Sol_cli_provider_capabilities.installation_probes provider configuration
  |> List.find_map (fun probe ->
    match probe with
    | Sol_cli_installation.Inspect probe when probe.prerequisite = prerequisite ->
      Some probe.argv
    | Sol_cli_installation.Inspect _ | Sol_cli_installation.Unavailable _ -> None)
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
    "the AWS root declares the four identities the target resolves as role ARNs"
    true
    (List.mem Sol_cli_installation.Provisioning_identity aws
     && List.mem Sol_cli_installation.Cluster_access_identity aws
     && List.mem Sol_cli_installation.Deploy_identity aws
     && List.mem Sol_cli_installation.Operator_identity aws);
  check_bool
    "the GCP durable root declares no identity of its own, so GCP has none to observe"
    false
    (List.mem Sol_cli_installation.Provisioning_identity gcp
     || List.mem Sol_cli_installation.Cluster_access_identity gcp
     || List.mem Sol_cli_installation.Deploy_identity gcp
     || List.mem Sol_cli_installation.Operator_identity gcp);
  check_bool
    "both installations are observed for the durable state and the delegated zone"
    true
    (List.mem Sol_cli_installation.State_backend aws
     && List.mem Sol_cli_installation.State_backend gcp
     && List.mem Sol_cli_installation.Delegated_zone aws
     && List.mem Sol_cli_installation.Delegated_zone gcp)
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
  match
    Sol_cli_installation.observe
      ~run:(fun _ -> Sol_cli_installation.Unobservable "no aws CLI in PATH")
      probes
  with
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

let test_a_refused_probe_is_unmet () =
  let probes =
    [ Sol_cli_installation.present_if_output
        Sol_cli_installation.State_backend
        [ "aws"; "s3api"; "head-bucket" ]
    ]
  in
  match
    Sol_cli_installation.observe
      ~run:(fun _ -> Sol_cli_installation.Absent "aws exited with code 254: Not Found")
      probes
  with
  | [ (_, Sol_cli_installation.Unmet reason) ] ->
    check_bool
      "the provider's own answer is carried through"
      true
      (String.length reason > 0)
  | [ (_, Sol_cli_installation.Unknown reason) ] ->
    Alcotest.fail ("a probe that ran and refused is Unmet, not UNKNOWN: " ^ reason)
  | [ (_, Sol_cli_installation.Established) ] ->
    Alcotest.fail "a refused probe was reported Established"
  | _ -> Alcotest.fail "expected one verdict"
;;

let test_observation_drives_the_verdict () =
  let probes =
    [ Sol_cli_installation.present_if_output
        Sol_cli_installation.State_backend
        [ "aws"; "s3api"; "head-bucket" ]
    ]
  in
  match
    Sol_cli_installation.observe ~run:(fun _ -> Sol_cli_installation.Observed "ok") probes
  with
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
    ; operator_identity = None
    ; zone_domain = None
    }
  in
  let inspected = ref [] in
  let verdicts =
    Sol_cli_provider_capabilities.installation_probes Sol_cli_provider.Aws bare
    |> Sol_cli_installation.observe ~run:(fun argv ->
      inspected := argv :: !inspected;
      Sol_cli_installation.Observed "present")
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

let test_resolves_the_declared_installation () =
  let aws = resolved_or_fail aws_target in
  check_string
    "the state prefix is derived plumbing, not a declaration"
    "bootstrap/aws"
    aws.state_prefix;
  check_string "the bucket is the target's declaration" "acme-tfstate" aws.state_bucket;
  check_string "the region is the target's declaration" "us-east-1" aws.region;
  Alcotest.(check (option string))
    "the lock table is the target's declaration"
    (Some "acme-tflock")
    aws.lock_table;
  Alcotest.(check (option string))
    "the provisioning identity is the declared ARN"
    (Some "arn:aws:iam::111122223333:role/sol-provisioner")
    aws.provisioning_identity;
  Alcotest.(check (option string))
    "the delegated zone follows the served domain"
    (Some "api.acme.example")
    aws.zone_domain;
  Alcotest.(check (option string))
    "an AWS installation names no project"
    None
    aws.project_id;
  let gcp = resolved_or_fail gcp_target in
  check_string "the GCP prefix is derived too" "bootstrap/gcp" gcp.state_prefix;
  Alcotest.(check (option string))
    "the GCP root declares no lock table, so none is resolved"
    None
    gcp.lock_table;
  Alcotest.(check (option string))
    "the GCP project is the target's declaration"
    (Some "sol-qualification")
    gcp.project_id;
  Alcotest.(check (option string))
    "the GCP durable root declares no identity, so none is resolved"
    None
    gcp.deploy_identity
;;

let test_the_state_backend_is_required () =
  match Sol_cli_installation.of_target { aws_target with state_bucket = None } with
  | Ok _ -> Alcotest.fail "an installation with no state backend was resolved"
  | Error message ->
    check_bool
      "the refusal names what is missing"
      true
      (Sol_cli_string.contains ~needle:"state_bucket" message)
;;

let test_the_role_probe_names_the_role_not_the_arn () =
  let configuration = resolved_or_fail aws_target in
  match
    probe_argv
      Sol_cli_provider.Aws
      configuration
      Sol_cli_installation.Provisioning_identity
  with
  | Some argv ->
    Alcotest.(check (list string))
      "get-role takes the role name, derived from the declared ARN"
      [ "aws"; "iam"; "get-role"; "--role-name"; "sol-provisioner" ]
      argv
  | None -> Alcotest.fail "the provisioning identity has no probe"
;;

let test_the_gcp_zone_probe_uses_the_zone_name_terraform_creates () =
  let configuration = resolved_or_fail gcp_target in
  match
    probe_argv Sol_cli_provider.Gcp configuration Sol_cli_installation.Delegated_zone
  with
  | Some argv ->
    Alcotest.(check (list string))
      "the durable root names its zone by replacing the dots"
      [ "gcloud"
      ; "dns"
      ; "managed-zones"
      ; "describe"
      ; "qual-gcp-example-test"
      ; "--format=value(name)"
      ]
      argv
  | None -> Alcotest.fail "the delegated zone has no probe"
;;

let test_the_durable_root_is_configured_from_the_declaration () =
  let aws = resolved_or_fail aws_target in
  (match Sol_cli_provider_capabilities.installation_backend Sol_cli_provider.Aws aws with
   | Error message ->
     Alcotest.fail ("the AWS durable root's backend was refused: " ^ message)
   | Ok backend ->
     Alcotest.(check (list string))
       "the durable root's own state lives under the derived prefix"
       [ "bucket=acme-tfstate"
       ; "key=bootstrap/aws/default.tfstate"
       ; "region=us-east-1"
       ; "dynamodb_table=acme-tflock"
       ; "encrypt=true"
       ]
       backend);
  (match
     Sol_cli_provider_capabilities.installation_vars
       Sol_cli_provider.Aws
       ~manage_dns_zone:true
       aws
   with
   | [ (_, "us-east-1")
     ; (_, "acme-tfstate")
     ; (_, "acme-tflock")
     ; ("manage_dns_zone", "true")
     ; ("base_domain", "api.acme.example")
     ] -> ()
   | vars ->
     Alcotest.fail
       ("the AWS durable root's variables are not the declared ones: "
        ^ String.concat "," (List.map fst vars)));
  let gcp = resolved_or_fail gcp_target in
  (match Sol_cli_provider_capabilities.installation_backend Sol_cli_provider.Gcp gcp with
   | Error message ->
     Alcotest.fail ("the GCP durable root's backend was refused: " ^ message)
   | Ok backend ->
     Alcotest.(check (list string))
       "the GCP backend is a prefix, not a key"
       [ "bucket=sol-qualification-tfstate"; "prefix=bootstrap/gcp" ]
       backend);
  let no_zone =
    Sol_cli_provider_capabilities.installation_vars
      Sol_cli_provider.Aws
      ~manage_dns_zone:false
      aws
  in
  Alcotest.(check (option string))
    "a root that does not own the zone is told so"
    (Some "false")
    (List.assoc_opt "manage_dns_zone" no_zone)
;;

let test_the_durable_root_refuses_an_incomplete_declaration () =
  let aws = resolved_or_fail aws_target in
  (match
     Sol_cli_provider_capabilities.installation_backend
       Sol_cli_provider.Aws
       { aws with lock_table = None }
   with
   | Ok _ -> Alcotest.fail "an AWS root with no lock table was configured"
   | Error message ->
     check_bool
       "the refusal names the lock table"
       true
       (Sol_cli_string.contains ~needle:"state_lock_table" message));
  let gcp = resolved_or_fail gcp_target in
  match
    Sol_cli_provider_capabilities.installation_vars
      Sol_cli_provider.Gcp
      ~manage_dns_zone:false
      { gcp with project_id = None }
  with
  | vars ->
    Alcotest.(check (option string))
      "a GCP root with no project still passes what the target declared"
      (Some "")
      (List.assoc_opt "project_id" vars)
;;

let test_the_durable_root_policy_refuses_recreation () =
  let open Sol_cli_terraform_plan in
  let change address action =
    { address; resource_type = "aws_s3_bucket"; mode = "managed"; action }
  in
  let policy = Sol_cli_installation_stage.durable_root_policy in
  Alcotest.(check int)
    "a metadata-only change is permitted"
    0
    (List.length (violations policy [ change "aws_s3_bucket.state" Update ]));
  Alcotest.(check int)
    "a creation is permitted, so the root can gain a durable resource"
    0
    (List.length (violations policy [ change "aws_dynamodb_table.lock" Create ]));
  Alcotest.(check int)
    "a replacement is refused"
    1
    (List.length (violations policy [ change "aws_s3_bucket.state" Replace ]));
  Alcotest.(check int)
    "a destruction is refused"
    1
    (List.length
       (violations policy [ change "aws_route53_zone.qualification[0]" Delete ]))
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
            "a probe that ran and refused is Unmet"
            `Quick
            test_a_refused_probe_is_unmet
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
        ; Alcotest.test_case
            "resolves the declared installation"
            `Quick
            test_resolves_the_declared_installation
        ; Alcotest.test_case
            "requires a state backend"
            `Quick
            test_the_state_backend_is_required
        ; Alcotest.test_case
            "the role probe names the role, not the ARN"
            `Quick
            test_the_role_probe_names_the_role_not_the_arn
        ; Alcotest.test_case
            "the GCP zone probe uses the zone name Terraform creates"
            `Quick
            test_the_gcp_zone_probe_uses_the_zone_name_terraform_creates
        ; Alcotest.test_case
            "the durable root is configured from the declaration"
            `Quick
            test_the_durable_root_is_configured_from_the_declaration
        ; Alcotest.test_case
            "an incomplete declaration is refused"
            `Quick
            test_the_durable_root_refuses_an_incomplete_declaration
        ; Alcotest.test_case
            "the durable root's policy refuses recreation and destruction"
            `Quick
            test_the_durable_root_policy_refuses_recreation
        ] )
    ]
;;
