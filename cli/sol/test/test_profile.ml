(* FEAT-089: production profile selection, plan carriage, preflight and the
   deployment-event claim, exercised through real workspace files. *)

module P = Sol_cli_profile
module Pre = Sol_cli_profile_preflight

let check_str = Alcotest.(check string)
let check_bool = Alcotest.(check bool)
let check_strs = Alcotest.(check (list string))

let contains ~needle s =
  let nlen = String.length needle
  and slen = String.length s in
  let rec loop i = i + nlen <= slen && (String.sub s i nlen = needle || loop (i + 1)) in
  nlen = 0 || loop 0
;;

let write path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let rec mkdir_p path =
  if path <> "" && path <> "." && not (Sys.file_exists path)
  then (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

let with_workspace f =
  let dir = Filename.temp_dir "sol-profile-test-" "" in
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Sys.chdir cwd)
    (fun () ->
       Sys.chdir dir;
       write "sol.yml" "project: pluto\n";
       f ())
;;

let write_target path body =
  mkdir_p (Filename.dirname path);
  write path body
;;

let prod_aws = "sol/prod/aws/us-east-1.yml"
let selecting = "target:\n  profile: production-single-region\n"

let load target =
  match Sol_cli_config.load_for_target ~target with
  | Ok cfg -> cfg
  | Error e -> Alcotest.fail (Sol_cli_config.error_to_string e)
;;

let load_error target =
  match Sol_cli_config.load_for_target ~target with
  | Ok _ -> Alcotest.fail "expected load_for_target to fail"
  | Error e -> e.message
;;

let target_of cfg = Option.get (Sol_cli_config.target cfg)
let profile_name (target : Sol_cli_config.target) = Option.map P.to_string target.profile

(* ── Identity and vocabulary ─────────────────────────────────────────────── *)

let test_identity_round_trips () =
  check_str
    "identity"
    "production-single-region/v1"
    (P.to_string P.Production_single_region);
  check_bool
    "of_string inverts to_string"
    true
    (P.of_string "production-single-region/v1" = Ok P.Production_single_region);
  check_bool
    "unknown version refused"
    true
    (Result.is_error (P.of_string "production-single-region/v2"));
  check_bool
    "selection name is unversioned"
    true
    (P.of_selection "production-single-region" = Ok P.Production_single_region)
;;

let test_requirements_follow_usage () =
  let names usage =
    P.requirements P.Production_single_region usage |> List.map P.capability_to_string
  in
  let always =
    [ "qualified_substrate"
    ; "qualified_versions"
    ; "direct_apply_authority"
    ; "remote_state"
    ; "scoped_operator_identities"
    ; "alert_delivery"
    ; "immutable_artifacts"
    ; "credential_posture"
    ]
  in
  check_strs "no used capabilities: target-level guarantees only" always (names []);
  check_strs
    "each used capability once, in a fixed order"
    (always @ [ "workload_availability"; "postgres_durability"; "kafka_durability" ])
    (names [ P.Kafka; P.Long_running; P.Postgres; P.Kafka ])
;;

(* ── Selection ───────────────────────────────────────────────────────────── *)

let test_prod_env_without_profile_claims_nothing () =
  with_workspace (fun () ->
    write_target prod_aws "target:\n  cluster_name: pluto-prod\n";
    check_bool
      "env named prod selects no profile"
      true
      (profile_name (target_of (load "prod/aws/us-east-1")) = None))
;;

let test_target_file_selects_profile () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    check_bool
      "profile selected"
      true
      (profile_name (target_of (load "prod/aws/us-east-1"))
       = Some "production-single-region/v1"))
;;

let test_profile_is_independent_of_env_name () =
  with_workspace (fun () ->
    write_target "sol/staging/aws/us-east-1.yml" selecting;
    check_bool
      "a non-prod env may select it explicitly"
      true
      (profile_name (target_of (load "staging/aws/us-east-1")) <> None))
;;

let test_unknown_profile_rejected () =
  with_workspace (fun () ->
    write_target prod_aws "target:\n  profile: production\n";
    check_bool
      "names the known profile"
      true
      (contains ~needle:"production-single-region" (load_error "prod/aws/us-east-1")))
;;

let test_shared_sol_yml_profile_rejected () =
  with_workspace (fun () ->
    write "sol.yml" "project: pluto\ntarget:\n  profile: production-single-region\n";
    write_target prod_aws "target:\n  cluster_name: pluto-prod\n";
    check_bool
      "sol.yml cannot opt every target in"
      true
      (contains ~needle:"target file" (load_error "prod/aws/us-east-1")))
;;

let test_unrelated_value_does_not_change_selection () =
  with_workspace (fun () ->
    write_target
      prod_aws
      "target:\n  profile: production-single-region\n  observability_backend: external\n";
    write_target
      "sol/dev/aws/us-east-1.yml"
      "target:\n  observability_backend: external\n";
    check_bool
      "selected stays selected"
      true
      (profile_name (target_of (load "prod/aws/us-east-1")) <> None);
    check_bool
      "unselected stays unselected"
      true
      (profile_name (target_of (load "dev/aws/us-east-1")) = None))
;;

(* ── Plan carriage ───────────────────────────────────────────────────────── *)

let env : Sol_cli_deployment_plan.env_config =
  { name = "pluto"
  ; mode = Sol_cli_deployment_plan.Customer_cloud
  ; registry = "registry.example.com"
  ; image_tag = "abc123"
  ; env = Some "prod"
  ; region = None
  ; base_domain = None
  ; cluster_issuer = "letsencrypt-prod"
  ; secret_backend = Sol_cli_manifest.Kubernetes_placeholder
  }
;;

let unit ~domain ~name primitive : Sol_cli_manifest.service =
  { domain; name; primitive; dir = Printf.sprintf "app/%s/%s" domain name }
;;

let charge_svc = unit ~domain:"payments" ~name:"charge_svc" Sol_cli_manifest.Svc

let plan_for ?(services = [ charge_svc ]) target =
  List.iter
    (fun (s : Sol_cli_manifest.service) ->
       mkdir_p s.dir;
       write (Filename.concat s.dir "sol.toml") "")
    services;
  match
    Sol_cli_deployment_plan.of_services_result
      ~workspace:"pluto"
      ~env
      ~resolved_config:(load target)
      services
  with
  | Ok plan -> plan
  | Error e -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string e)
;;

let requirements_of plan =
  match plan.Sol_cli_deployment_plan.profile with
  | None -> Alcotest.fail "expected a profile claim"
  | Some claim -> claim.requirements
;;

let test_plan_carries_claim_and_requirements () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    let plan = plan_for "prod/aws/us-east-1" in
    match plan.profile with
    | None -> Alcotest.fail "expected a profile claim"
    | Some claim ->
      check_str "identity" "production-single-region/v1" (P.to_string claim.profile);
      check_bool
        "a service makes availability applicable"
        true
        (List.mem P.Workload_availability claim.requirements);
      check_bool
        "no data services, no data durability requirement"
        false
        (List.mem P.Postgres_durability claim.requirements
         || List.mem P.Kafka_durability claim.requirements);
      let json = Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan) in
      check_bool
        "plan JSON carries the identity"
        true
        (contains ~needle:{|"id":"production-single-region/v1"|} json);
      check_bool
        "plan JSON carries evidence requirements"
        true
        (contains ~needle:{|"evidence_requirements":[|} json))
;;

let test_declared_data_resources_make_durability_applicable () =
  with_workspace (fun () ->
    write
      "sol.yml"
      "project: pluto\n\
       resources:\n\
      \  app_db:\n\
      \    type: postgres\n\
      \  events:\n\
      \    type: kafka\n";
    write_target prod_aws selecting;
    match (plan_for "prod/aws/us-east-1").profile with
    | None -> Alcotest.fail "expected a profile claim"
    | Some claim ->
      check_bool
        "postgres resource requires Postgres durability"
        true
        (List.mem P.Postgres_durability claim.requirements);
      check_bool
        "kafka resource requires Kafka durability"
        true
        (List.mem P.Kafka_durability claim.requirements))
;;

let notify_worker = unit ~domain:"comms" ~name:"notify_worker" Sol_cli_manifest.Worker

let test_worker_shape_does_not_imply_kafka () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    (* An OCaml event module is language-specific source, not a declaration. *)
    mkdir_p "events/comms";
    write "events/comms/email_requested.ml" "";
    let requirements =
      requirements_of (plan_for ~services:[ notify_worker ] "prod/aws/us-east-1")
    in
    check_bool
      "a worker is still long-running"
      true
      (List.mem P.Workload_availability requirements);
    check_bool
      "an undeclared worker requires no Kafka durability"
      false
      (List.mem P.Kafka_durability requirements))
;;

let test_declared_kafka_use_applies_durability_policy () =
  with_workspace (fun () ->
    write
      "sol.yml"
      "project: pluto\n\
       resources:\n\
      \  events:\n\
      \    type: kafka\n\
       services:\n\
      \  notify_worker:\n\
      \    uses: [events]\n";
    write_target prod_aws selecting;
    let plan = plan_for ~services:[ notify_worker ] "prod/aws/us-east-1" in
    let worker = List.hd plan.services in
    check_str
      "semantic durability policy"
      "single-broker-loss"
      (List.assoc "SOL_KAFKA_DURABILITY" worker.config);
    Alcotest.(check int)
      "declared Kafka worker group"
      1
      (List.length plan.consumer_groups))
;;

let test_jobs_worker_requires_postgres_not_kafka () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    mkdir_p "db/migrations";
    write "db/migrations/001_jobs.sql" "";
    let requirements =
      requirements_of (plan_for ~services:[ notify_worker ] "prod/aws/us-east-1")
    in
    check_bool
      "migrations require Postgres durability"
      true
      (List.mem P.Postgres_durability requirements);
    check_bool "no Kafka durability" false (List.mem P.Kafka_durability requirements))
;;

let test_declared_topics_require_kafka () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    mkdir_p "events/comms";
    write "events/comms/sol.toml" "[service]\ntopics = [\"comms-emails\"]\n";
    check_bool
      "a declared topic requires Kafka durability"
      true
      (List.mem
         P.Kafka_durability
         (requirements_of (plan_for ~services:[ notify_worker ] "prod/aws/us-east-1"))))
;;

let test_plan_without_profile_is_unchanged () =
  with_workspace (fun () ->
    write_target prod_aws "target:\n  cluster_name: pluto-prod\n";
    let plan = plan_for "prod/aws/us-east-1" in
    check_bool "no claim" true (plan.profile = None);
    check_bool
      "JSON profile is null"
      true
      (contains
         ~needle:{|"profile":null|}
         (Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan))))
;;

let test_profile_does_not_change_release_identity () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    write_target "sol/prod/aws/us-west-2.yml" "target:\n  cluster_name: pluto-west\n";
    let claimed = plan_for "prod/aws/us-east-1" in
    let unclaimed = plan_for "prod/aws/us-west-2" in
    check_str
      "same content, same release, with or without a profile"
      (Sol_cli_release_id.to_string unclaimed.release_id)
      (Sol_cli_release_id.to_string claimed.release_id))
;;

(* ── Preflight ───────────────────────────────────────────────────────────── *)

let preflight ?establish ~apply_mode target =
  let plan = plan_for target in
  Pre.check ?establish ~target:(target_of (load target)) ~apply_mode plan
;;

let findings = function
  | Ok () -> Alcotest.fail "expected preflight to fail closed"
  | Error (_, fs) -> fs
;;

let capabilities fs =
  List.map (fun (f : Pre.finding) -> P.capability_to_string f.capability) fs
;;

let test_no_profile_skips_preflight () =
  with_workspace (fun () ->
    write_target "sol/prod/gcp/us-central1.yml" "target:\n  cluster_name: pluto\n";
    check_bool
      "an unqualified provider and GitOps are fine without a profile"
      true
      (preflight ~apply_mode:Sol_cli_release.Gitops "prod/gcp/us-central1" = Ok ()))
;;

let test_unestablished_guarantees_fail_closed () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    let fs =
      findings (preflight ~apply_mode:Sol_cli_release.Direct "prod/aws/us-east-1")
    in
    check_strs
      "every guarantee Sol cannot establish yet is unmet"
      [ "qualified_versions"
      ; "remote_state"
      ; "scoped_operator_identities"
      ; "alert_delivery"
      ; "immutable_artifacts"
      ; "credential_posture"
      ; "workload_availability"
      ]
      (capabilities fs);
    check_bool
      "all attributed to the platform, not the user"
      true
      (List.for_all (fun (f : Pre.finding) -> f.side = Pre.Platform) fs))
;;

let test_unqualified_provider_is_a_target_finding () =
  with_workspace (fun () ->
    write_target "sol/prod/gcp/us-central1.yml" selecting;
    let fs =
      findings (preflight ~apply_mode:Sol_cli_release.Direct "prod/gcp/us-central1")
    in
    match
      List.find_opt (fun (f : Pre.finding) -> f.capability = P.Qualified_substrate) fs
    with
    | None -> Alcotest.fail "expected a substrate finding"
    | Some f ->
      check_bool "target side" true (f.side = Pre.Target);
      check_bool "names the provider" true (contains ~needle:"gcp" f.reason))
;;

let test_emit_to_rejected_for_profile () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    let fs =
      findings (preflight ~apply_mode:Sol_cli_release.Gitops "prod/aws/us-east-1")
    in
    check_bool
      "direct apply authority unmet"
      true
      (List.exists
         (fun (f : Pre.finding) ->
            f.capability = P.Direct_apply_authority && f.side = Pre.Target)
         fs))
;;

let test_kafka_dependency_declaration_required () =
  with_workspace (fun () ->
    write "sol.yml" "project: pluto\nresources:\n  events:\n    type: kafka\n";
    write_target prod_aws selecting;
    let fs =
      findings (preflight ~apply_mode:Sol_cli_release.Direct "prod/aws/us-east-1")
    in
    match
      List.find_opt (fun (f : Pre.finding) -> f.capability = P.Kafka_durability) fs
    with
    | None -> Alcotest.fail "expected an undeclared Kafka dependency finding"
    | Some finding ->
      check_bool "application side" true (finding.side = Pre.Application);
      check_bool "names uses" true (contains ~needle:"uses:" finding.reason))
;;

let test_postgres_resource_declaration_required () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    mkdir_p "db/migrations";
    write "db/migrations/001.sql" "select 1;\n";
    let fs =
      findings (preflight ~apply_mode:Sol_cli_release.Direct "prod/aws/us-east-1")
    in
    match
      List.find_opt (fun (f : Pre.finding) -> f.capability = P.Postgres_durability) fs
    with
    | None -> Alcotest.fail "expected a missing Postgres resource finding"
    | Some finding ->
      check_bool "application side" true (finding.side = Pre.Application);
      check_bool
        "names resource declaration"
        true
        (contains ~needle:"resource" finding.reason))
;;

let test_all_established_passes () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    check_bool
      "a target establishing every guarantee passes"
      true
      (preflight
         ~establish:(fun _ -> Pre.Established)
         ~apply_mode:Sol_cli_release.Direct
         "prod/aws/us-east-1"
       = Ok ()))
;;

let test_report_speaks_in_guarantees () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    let fs =
      findings (preflight ~apply_mode:Sol_cli_release.Direct "prod/aws/us-east-1")
    in
    let report = Pre.report P.Production_single_region fs in
    check_bool "says nothing changed" true (contains ~needle:"Nothing was changed" report);
    check_bool
      "names the unmet guarantee"
      true
      (contains ~needle:"immutable artifact identity is not established" report);
    check_bool
      "carries no ticket ids"
      false
      (List.exists
         (fun needle -> contains ~needle report)
         [ "FEAT-"; "AUDIT-"; "SEC-"; "OBS-"; "DEC-" ]))
;;

(* ── Deployment event ────────────────────────────────────────────────────── *)

let event_of plan =
  Sol_cli_deployment.of_plan
    ~deployment_id:(Sol_cli_deployment_id.create ~now:1767225600.0 ~entropy:"seed")
    ~now:1767225600.0
    ~git_commit:"abc1234"
    ~git_dirty:false
    ~actor:None
    ~target:(Some "prod/aws/us-east-1")
    ~outcome:Sol_cli_deployment.Applied
    plan
;;

let test_event_records_claim () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    let event = event_of (plan_for "prod/aws/us-east-1") in
    check_bool
      "event carries the claim"
      true
      (event.profile = Some P.Production_single_region);
    match Sol_cli_deployment.of_json (Sol_cli_deployment.to_json event) with
    | Error e -> Alcotest.fail e
    | Ok back -> check_bool "round-trips" true (back.profile = event.profile))
;;

let with_profile_field value =
  with_workspace (fun () ->
    write_target prod_aws "target:\n  cluster_name: pluto-prod\n";
    match Sol_cli_deployment.to_json (event_of (plan_for "prod/aws/us-east-1")) with
    | `Assoc kvs ->
      Sol_cli_deployment.of_json
        (`Assoc
            (List.filter_map
               (fun (k, v) ->
                  if k <> "profile" then Some (k, v) else Option.map (fun v -> k, v) value)
               kvs))
    | _ -> Alcotest.fail "expected an object")
;;

let test_event_without_profile_field_claims_nothing () =
  match with_profile_field None with
  | Ok event -> check_bool "no claim" true (event.profile = None)
  | Error e -> Alcotest.fail e
;;

let test_event_with_unknown_profile_rejected () =
  check_bool
    "unknown identity is an error, not a weaker claim"
    true
    (Result.is_error (with_profile_field (Some (`String "production-single-region/v9"))))
;;

let () =
  Alcotest.run
    "profile"
    [ ( "identity"
      , [ Alcotest.test_case "round trips" `Quick test_identity_round_trips
        ; Alcotest.test_case
            "requirements follow usage"
            `Quick
            test_requirements_follow_usage
        ] )
    ; ( "selection"
      , [ Alcotest.test_case
            "prod env without profile claims nothing"
            `Quick
            test_prod_env_without_profile_claims_nothing
        ; Alcotest.test_case "target file selects" `Quick test_target_file_selects_profile
        ; Alcotest.test_case
            "independent of env name"
            `Quick
            test_profile_is_independent_of_env_name
        ; Alcotest.test_case
            "unknown profile rejected"
            `Quick
            test_unknown_profile_rejected
        ; Alcotest.test_case
            "shared sol.yml profile rejected"
            `Quick
            test_shared_sol_yml_profile_rejected
        ; Alcotest.test_case
            "unrelated value does not change selection"
            `Quick
            test_unrelated_value_does_not_change_selection
        ] )
    ; ( "plan"
      , [ Alcotest.test_case
            "carries claim and requirements"
            `Quick
            test_plan_carries_claim_and_requirements
        ; Alcotest.test_case
            "declared data resources make durability applicable"
            `Quick
            test_declared_data_resources_make_durability_applicable
        ; Alcotest.test_case
            "worker shape does not imply Kafka"
            `Quick
            test_worker_shape_does_not_imply_kafka
        ; Alcotest.test_case
            "declared Kafka use applies durability policy"
            `Quick
            test_declared_kafka_use_applies_durability_policy
        ; Alcotest.test_case
            "jobs worker requires Postgres, not Kafka"
            `Quick
            test_jobs_worker_requires_postgres_not_kafka
        ; Alcotest.test_case
            "declared topics require Kafka"
            `Quick
            test_declared_topics_require_kafka
        ; Alcotest.test_case
            "no profile, unchanged plan"
            `Quick
            test_plan_without_profile_is_unchanged
        ; Alcotest.test_case
            "profile does not change release identity"
            `Quick
            test_profile_does_not_change_release_identity
        ] )
    ; ( "preflight"
      , [ Alcotest.test_case "no profile skips" `Quick test_no_profile_skips_preflight
        ; Alcotest.test_case
            "unestablished guarantees fail closed"
            `Quick
            test_unestablished_guarantees_fail_closed
        ; Alcotest.test_case
            "unqualified provider is a target finding"
            `Quick
            test_unqualified_provider_is_a_target_finding
        ; Alcotest.test_case "emit-to rejected" `Quick test_emit_to_rejected_for_profile
        ; Alcotest.test_case
            "Kafka dependency declaration required"
            `Quick
            test_kafka_dependency_declaration_required
        ; Alcotest.test_case
            "Postgres resource declaration required"
            `Quick
            test_postgres_resource_declaration_required
        ; Alcotest.test_case "all established passes" `Quick test_all_established_passes
        ; Alcotest.test_case
            "report speaks in guarantees"
            `Quick
            test_report_speaks_in_guarantees
        ] )
    ; ( "deployment event"
      , [ Alcotest.test_case "records the claim" `Quick test_event_records_claim
        ; Alcotest.test_case
            "missing field claims nothing"
            `Quick
            test_event_without_profile_field_claims_nothing
        ; Alcotest.test_case
            "unknown profile rejected"
            `Quick
            test_event_with_unknown_profile_rejected
        ] )
    ]
;;
