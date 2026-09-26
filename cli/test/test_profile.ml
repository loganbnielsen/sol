(* FEAT-089: production profile selection, plan carriage, preflight and the
   deployment-event claim, exercised through real workspace files. *)

module P = Sol_cli_profile
module Pre = Sol_cli_profile_preflight

let check_str = Alcotest.(check string)
let check_bool = Alcotest.(check bool)
let check_strs = Alcotest.(check (list string))

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

(* FEAT-100: [path] is a target address, <env>/<provider>/<region>. *)
let write_target path body = Targets_fixture.write ~target:path body
let prod_aws = "prod/aws/us-east-1"
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

let target_of cfg = cfg.Sol_cli_config.target
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
    ; "platform_capacity"
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
    write_target "staging/aws/us-east-1" selecting;
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
      (Sol_cli_string.contains
         ~needle:"production-single-region"
         (load_error "prod/aws/us-east-1")))
;;

let test_shared_sol_yml_profile_rejected () =
  with_workspace (fun () ->
    write "sol.yml" "project: pluto\ntarget:\n  profile: production-single-region\n";
    write_target prod_aws "target:\n  cluster_name: pluto-prod\n";
    check_bool
      "sol.yml cannot opt every target in"
      true
      (Sol_cli_string.contains
         ~needle:"environment or target"
         (load_error "prod/aws/us-east-1")))
;;

let test_unrelated_value_does_not_change_selection () =
  with_workspace (fun () ->
    write_target
      prod_aws
      "target:\n  profile: production-single-region\n  observability_backend: external\n";
    write_target "dev/aws/us-east-1" "target:\n  observability_backend: external\n";
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

(* INFRA-038: the stateless case -- a Service that declares no resource use at
   all, mirroring examples/pluto's checkout_svc. *)
let checkout_svc = unit ~domain:"checkout" ~name:"checkout_svc" Sol_cli_manifest.Svc

let plan_for ?(services = [ charge_svc ]) ?(image_refs = []) ?scope target =
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
      ~image_refs
      ?requested_scope:scope
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

(* INFRA-038: the findings a plan reports about the *workload*, as opposed to the
   requirements it places on the target. *)
let findings_of plan =
  match plan.Sol_cli_deployment_plan.profile with
  | None -> Alcotest.fail "expected a profile claim"
  | Some claim -> claim.application_findings
;;

let kafka_findings plan =
  List.filter (fun (capability, _) -> capability = P.Kafka_durability) (findings_of plan)
;;

(* AUDIT-080: a node-failure-tolerant workload needs at least two replicas; the
   preflight then checks the target declares enough headroom to restore them. *)
let node_failure_tolerant_plan target =
  mkdir_p charge_svc.dir;
  write
    (Filename.concat charge_svc.dir "sol.toml")
    "[infra.scale]\nreplicas = 2\navailability = \"node-failure-tolerant\"\n";
  match
    Sol_cli_deployment_plan.of_services_result
      ~workspace:"pluto"
      ~env
      ~resolved_config:(load target)
      [ charge_svc ]
  with
  | Ok plan -> plan
  | Error e -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string e)
;;

(* AUDIT-080: an availability claim the workload cannot satisfy is refused
   before render, naming a supported alternative. *)
let availability_rejection service ~toml =
  mkdir_p service.Sol_cli_manifest.dir;
  write (Filename.concat service.Sol_cli_manifest.dir "sol.toml") toml;
  match
    Sol_cli_deployment_plan.of_services_result
      ~workspace:"pluto"
      ~env
      ~resolved_config:(load "prod/aws/us-east-1")
      [ service ]
  with
  | Ok _ -> Alcotest.fail "expected the availability claim to be refused"
  | Error (Sol_cli_deployment_plan.Unsupported_availability { message; _ }) -> message
  | Error e -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string e)
;;

let charge_fn = unit ~domain:"payments" ~name:"charge_fn" Sol_cli_manifest.Fn

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
        (Sol_cli_string.contains ~needle:{|"id":"production-single-region/v1"|} json);
      check_bool
        "plan JSON carries evidence requirements"
        true
        (Sol_cli_string.contains ~needle:{|"evidence_requirements":[|} json))
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

(* INFRA-038. A Service acquires a Kafka requirement by declaring one. The target
   being *able* to provide Kafka durability is a property of the target, and it
   must not attach itself to every workload deployed onto it -- which is what made
   the stateless checkout_svc undeployable on its own, since no scope containing
   it could satisfy a check that asked whether some Service in the scope used
   Kafka. *)
let kafka_workspace =
  "project: pluto\n\
   resources:\n\
  \  app_db:\n\
  \    type: postgres\n\
  \  events:\n\
  \    type: kafka\n\
   services:\n\
  \  checkout_svc:\n\
  \    path: app/checkout/checkout_svc\n\
  \    language: ocaml\n\
  \  notify_worker:\n\
  \    uses: [events]\n\
  \    path: app/comms/notify_worker\n\
  \    language: ocaml\n"
;;

let test_stateless_scope_acquires_no_kafka_requirement () =
  with_workspace (fun () ->
    write "sol.yml" kafka_workspace;
    write_target prod_aws selecting;
    mkdir_p "events/comms";
    write "events/comms/sol.toml" "[service]\ntopics = [\"comms-emails\"]\n";
    let plan =
      plan_for
        ~services:[ checkout_svc ]
        ~scope:"checkout/checkout_svc"
        "prod/aws/us-east-1"
    in
    check_bool
      "a scope that declares no Kafka use acquires no Kafka finding"
      true
      (kafka_findings plan = []))
;;

let test_scope_declaring_kafka_is_unaffected () =
  with_workspace (fun () ->
    write "sol.yml" kafka_workspace;
    write_target prod_aws selecting;
    mkdir_p "events/comms";
    write "events/comms/sol.toml" "[service]\ntopics = [\"comms-emails\"]\n";
    let plan =
      plan_for
        ~services:[ notify_worker ]
        ~scope:"comms/notify_worker"
        "prod/aws/us-east-1"
    in
    check_bool
      "a Service that declares the use raises no finding"
      true
      (kafka_findings plan = []))
;;

let test_whole_workspace_topic_without_declaration_fails_closed () =
  with_workspace (fun () ->
    (* No Service declares the Kafka use, but the workspace declares topics -- so
       something here is meant to handle them. This is the mismatch that can be
       established, and it is the only Kafka case the deploy path should refuse. *)
    write
      "sol.yml"
      "project: pluto\n\
       resources:\n\
      \  app_db:\n\
      \    type: postgres\n\
      \  events:\n\
      \    type: kafka\n\
       services:\n\
      \  checkout_svc:\n\
      \    path: app/checkout/checkout_svc\n\
      \    language: ocaml\n\
      \  notify_worker:\n\
      \    path: app/comms/notify_worker\n\
      \    language: ocaml\n";
    write_target prod_aws selecting;
    mkdir_p "events/comms";
    write "events/comms/sol.toml" "[service]\ntopics = [\"comms-emails\"]\n";
    let plan = plan_for ~services:[ checkout_svc; notify_worker ] "prod/aws/us-east-1" in
    check_bool
      "a workspace-wide selection with no declaration still fails closed"
      true
      (kafka_findings plan <> []))
;;

let test_plan_without_profile_is_unchanged () =
  with_workspace (fun () ->
    write_target prod_aws "target:\n  cluster_name: pluto-prod\n";
    let plan = plan_for "prod/aws/us-east-1" in
    check_bool "no claim" true (plan.profile = None);
    check_bool
      "JSON profile is null"
      true
      (Sol_cli_string.contains
         ~needle:{|"profile":null|}
         (Yojson.Safe.to_string (Sol_cli_deployment_plan.to_json plan))))
;;

let test_profile_does_not_change_release_identity () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    write_target "prod/aws/us-west-2" "target:\n  cluster_name: pluto-west\n";
    let claimed = plan_for "prod/aws/us-east-1" in
    let unclaimed = plan_for "prod/aws/us-west-2" in
    check_str
      "same content, same release, with or without a profile"
      (Sol_cli_release_id.to_string unclaimed.release_id)
      (Sol_cli_release_id.to_string claimed.release_id))
;;

(* ── Preflight ───────────────────────────────────────────────────────────── *)

let preflight ?establish ?plan ~apply_mode target =
  let plan = Option.value plan ~default:(plan_for target) in
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
    write_target "prod/gcp/us-central1" "target:\n  cluster_name: pluto\n";
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
      "every guarantee that is not yet established is unmet (credential posture is now \
       established by the renderer)"
      [ "qualified_versions"
      ; "remote_state"
      ; "scoped_operator_identities"
      ; "alert_delivery"
      ; "immutable_artifacts"
      ]
      (capabilities fs);
    check_bool
      "Sol-owned guarantees are attributed to Sol; the artifact and version guarantees \
       to the application; alert, state and identity to the target"
      true
      (List.for_all
         (fun (f : Pre.finding) ->
            match f.capability with
            | P.Alert_delivery | P.Remote_state | P.Scoped_operator_identities ->
              f.side = Pre.Target
            | P.Immutable_artifacts | P.Qualified_versions -> f.side = Pre.Application
            | _ -> f.side = Pre.Platform)
         fs))
;;

let test_remote_state_requires_a_backend () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    let fs =
      findings (preflight ~apply_mode:Sol_cli_release.Direct "prod/aws/us-east-1")
    in
    match List.find_opt (fun (f : Pre.finding) -> f.capability = P.Remote_state) fs with
    | None -> Alcotest.fail "expected a remote-state finding"
    | Some f ->
      check_bool "target side" true (f.side = Pre.Target);
      check_bool
        "names the declarations"
        true
        (Sol_cli_string.contains ~needle:"state_bucket" f.reason))
;;

let test_remote_state_established_by_declaration () =
  with_workspace (fun () ->
    write_target
      prod_aws
      "target:\n\
      \  profile: production-single-region\n\
      \  state_bucket: acme-tfstate\n\
      \  aws:\n\
      \    state_lock_table: acme-tflock\n";
    let fs =
      findings (preflight ~apply_mode:Sol_cli_release.Direct "prod/aws/us-east-1")
    in
    check_bool
      "a declared bucket and lock table establish remote state"
      false
      (List.exists (fun (f : Pre.finding) -> f.capability = P.Remote_state) fs))
;;

let test_scoped_identities_require_roles_and_cidr () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    let fs =
      findings (preflight ~apply_mode:Sol_cli_release.Direct "prod/aws/us-east-1")
    in
    match
      List.find_opt
        (fun (f : Pre.finding) -> f.capability = P.Scoped_operator_identities)
        fs
    with
    | None -> Alcotest.fail "expected a scoped-identity finding"
    | Some f ->
      check_bool "target side" true (f.side = Pre.Target);
      check_bool
        "names the missing identity"
        true
        (Sol_cli_string.contains ~needle:"provisioner_role_arn" f.reason))
;;

let test_world_reachable_endpoint_is_rejected () =
  with_workspace (fun () ->
    write_target
      prod_aws
      "target:\n\
      \  profile: production-single-region\n\
      \  aws:\n\
      \    provisioner_role_arn: arn:aws:iam::1:role/provisioner\n\
      \    cluster_access_role_arn: arn:aws:iam::1:role/cluster-access\n\
      \    deploy_role_arn: arn:aws:iam::1:role/deploy\n\
      \    operator_role_arn: arn:aws:iam::1:role/operator\n\
      \  cluster_endpoint_cidr: 0.0.0.0/0\n";
    let fs =
      findings (preflight ~apply_mode:Sol_cli_release.Direct "prod/aws/us-east-1")
    in
    match
      List.find_opt
        (fun (f : Pre.finding) -> f.capability = P.Scoped_operator_identities)
        fs
    with
    | None -> Alcotest.fail "expected a scoped-identity finding for 0.0.0.0/0"
    | Some f ->
      check_bool
        "explains the restriction"
        true
        (Sol_cli_string.contains ~needle:"0.0.0.0/0" f.reason))
;;

let test_scoped_identities_established () =
  with_workspace (fun () ->
    write_target
      prod_aws
      "target:\n\
      \  profile: production-single-region\n\
      \  aws:\n\
      \    provisioner_role_arn: arn:aws:iam::1:role/provisioner\n\
      \    cluster_access_role_arn: arn:aws:iam::1:role/cluster-access\n\
      \    deploy_role_arn: arn:aws:iam::1:role/deploy\n\
      \    operator_role_arn: arn:aws:iam::1:role/operator\n\
      \  cluster_endpoint_cidr: 203.0.113.0/24\n";
    let fs =
      findings (preflight ~apply_mode:Sol_cli_release.Direct "prod/aws/us-east-1")
    in
    check_bool
      "named identities and a restricted CIDR establish the identity guarantee"
      false
      (List.exists
         (fun (f : Pre.finding) -> f.capability = P.Scoped_operator_identities)
         fs))
;;

let test_mutable_tag_is_an_application_finding () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    let fs =
      findings (preflight ~apply_mode:Sol_cli_release.Direct "prod/aws/us-east-1")
    in
    match
      List.find_opt (fun (f : Pre.finding) -> f.capability = P.Immutable_artifacts) fs
    with
    | None -> Alcotest.fail "expected an artifact finding for a tag image"
    | Some f ->
      check_bool "application side" true (f.side = Pre.Application);
      check_bool
        "names the --image-ref fix"
        true
        (Sol_cli_string.contains ~needle:"--image-ref" f.reason))
;;

let test_digest_plan_establishes_artifact_guarantee () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    let digest =
      "123456789012.dkr.ecr.us-east-1.amazonaws.com/pluto/charge-svc@sha256:"
      ^ String.make 64 'a'
    in
    let plan = plan_for ~image_refs:[ "charge_svc", digest ] "prod/aws/us-east-1" in
    let fs =
      findings (preflight ~plan ~apply_mode:Sol_cli_release.Direct "prod/aws/us-east-1")
    in
    check_bool
      "no artifact finding when every workload is a digest"
      false
      (List.exists (fun (f : Pre.finding) -> f.capability = P.Immutable_artifacts) fs);
    match plan.services with
    | [ spec ] ->
      check_str "plan image is the digest" digest spec.Sol_cli_deployment_plan.image
    | _ -> Alcotest.fail "expected exactly one planned service")
;;

let finding_for capability fs =
  List.find_opt (fun (f : Pre.finding) -> f.capability = capability) fs
;;

let test_undeclared_language_is_an_application_finding () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    let fs =
      findings (preflight ~apply_mode:Sol_cli_release.Direct "prod/aws/us-east-1")
    in
    match finding_for P.Qualified_versions fs with
    | None -> Alcotest.fail "expected an undeclared-language finding"
    | Some f ->
      check_bool "application side" true (f.side = Pre.Application);
      check_bool
        "names the language declaration"
        true
        (Sol_cli_string.contains ~needle:"language" f.reason))
;;

let test_declared_ocaml_establishes_versions () =
  with_workspace (fun () ->
    write "sol.yml" "project: pluto\nservices:\n  charge_svc:\n    language: ocaml\n";
    write_target prod_aws selecting;
    let fs =
      findings (preflight ~apply_mode:Sol_cli_release.Direct "prod/aws/us-east-1")
    in
    check_bool
      "a declared OCaml workload establishes the version guarantee"
      false
      (List.exists (fun (f : Pre.finding) -> f.capability = P.Qualified_versions) fs))
;;

let test_typescript_is_not_qualified () =
  with_workspace (fun () ->
    write "sol.yml" "project: pluto\nservices:\n  charge_svc:\n    language: typescript\n";
    write_target prod_aws selecting;
    let fs =
      findings (preflight ~apply_mode:Sol_cli_release.Direct "prod/aws/us-east-1")
    in
    match finding_for P.Qualified_versions fs with
    | None -> Alcotest.fail "expected a TypeScript-not-qualified finding"
    | Some f ->
      check_bool "application side" true (f.side = Pre.Application);
      check_bool
        "names the language and the alternative"
        true
        (Sol_cli_string.contains ~needle:"typescript" f.reason))
;;

let test_missing_alert_receiver_is_a_target_finding () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    let fs =
      findings (preflight ~apply_mode:Sol_cli_release.Direct "prod/aws/us-east-1")
    in
    match List.find_opt (fun (f : Pre.finding) -> f.capability = P.Alert_delivery) fs with
    | None -> Alcotest.fail "expected an alert-delivery finding"
    | Some f ->
      check_bool "target side" true (f.side = Pre.Target);
      check_bool
        "names the receiver declaration"
        true
        (Sol_cli_string.contains ~needle:"alert_receiver_type" f.reason))
;;

let test_complete_alert_contract_establishes_delivery () =
  with_workspace (fun () ->
    write_target
      prod_aws
      "target:\n\
      \  profile: production-single-region\n\
      \  alert_receiver_type: webhook\n\
      \  alert_receiver_url: https://hooks.example.com/sol-alerts\n\
      \  alert_owner: payments-oncall\n\
      \  alert_runbook_url: https://runbooks.example.com/sol\n";
    let fs =
      findings (preflight ~apply_mode:Sol_cli_release.Direct "prod/aws/us-east-1")
    in
    check_bool
      "a complete receiver/owner/runbook declaration establishes delivery"
      false
      (List.exists (fun (f : Pre.finding) -> f.capability = P.Alert_delivery) fs))
;;

let test_unroutable_alert_receiver_is_a_target_finding () =
  with_workspace (fun () ->
    write_target
      prod_aws
      "target:\n\
      \  profile: production-single-region\n\
      \  alert_receiver_type: webhook\n\
      \  alert_receiver_url: not-a-url\n\
      \  alert_owner: payments-oncall\n\
      \  alert_runbook_url: https://runbooks.example.com/sol\n";
    let fs =
      findings (preflight ~apply_mode:Sol_cli_release.Direct "prod/aws/us-east-1")
    in
    match List.find_opt (fun (f : Pre.finding) -> f.capability = P.Alert_delivery) fs with
    | None -> Alcotest.fail "expected an unroutable-receiver finding"
    | Some f ->
      check_bool "target side" true (f.side = Pre.Target);
      check_bool
        "explains routability"
        true
        (Sol_cli_string.contains ~needle:"routable" f.reason))
;;

let test_unqualified_provider_is_a_target_finding () =
  with_workspace (fun () ->
    write_target "prod/gcp/us-central1" selecting;
    let fs =
      findings (preflight ~apply_mode:Sol_cli_release.Direct "prod/gcp/us-central1")
    in
    match
      List.find_opt (fun (f : Pre.finding) -> f.capability = P.Qualified_substrate) fs
    with
    | None -> Alcotest.fail "expected a substrate finding"
    | Some f ->
      check_bool "target side" true (f.side = Pre.Target);
      check_bool
        "names the provider"
        true
        (Sol_cli_string.contains ~needle:"gcp" f.reason))
;;

(* SEC-004: credential posture is a Sol-owned property of the renderer, so the
   guarantee is established for every plan regardless of target/application. *)
(* HARDEN-002 (run 1): the profile's durability guarantees were mapped to
   not_yet_established, so every profile target failed preflight and no deploy
   could run. They are now established from the configuration evidence the plan
   and target actually carry -- never from live behaviour, which is HARDEN-002's
   to measure. *)

let kafka_consumer_plan plan =
  { plan with
    Sol_cli_deployment_plan.services =
      List.map
        (fun (s : Sol_cli_deployment_plan.service_spec) ->
           { s with
             consumes_kafka = true
           ; config = ("SOL_KAFKA_DURABILITY", "single-broker-loss") :: s.config
           })
        plan.Sol_cli_deployment_plan.services
  }
;;

let test_durability_established_for_a_qualified_target () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    let plan = kafka_consumer_plan (plan_for "prod/aws/us-east-1") in
    let target = target_of (load "prod/aws/us-east-1") in
    check_bool
      "Postgres durability is established by the profile-derived Multi-AZ configuration"
      true
      (Pre.establish
         ~target
         ~apply_mode:Sol_cli_release.Direct
         ~plan
         P.Postgres_durability
       = Pre.Established);
    check_bool
      "Kafka durability is established by the rendered durability requirement"
      true
      (Pre.establish ~target ~apply_mode:Sol_cli_release.Direct ~plan P.Kafka_durability
       = Pre.Established))
;;

let test_durability_fails_closed_for_an_unqualified_provider () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    let plan = kafka_consumer_plan (plan_for "prod/aws/us-east-1") in
    let target =
      { (target_of (load "prod/aws/us-east-1")) with
        Sol_cli_config.provider = Sol_cli_provider.Gcp
      }
    in
    let unmet capability =
      match Pre.establish ~target ~apply_mode:Sol_cli_release.Direct ~plan capability with
      | Pre.Unmet (Pre.Target, _) -> true
      | _ -> false
    in
    check_bool "Postgres durability fails closed" true (unmet P.Postgres_durability);
    check_bool "Kafka durability fails closed" true (unmet P.Kafka_durability))
;;

let test_kafka_durability_requires_the_rendered_requirement () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    (* A declared Kafka consumer whose plan does not carry the qualified
       durability requirement must not pass. *)
    let plan =
      { (plan_for "prod/aws/us-east-1") with
        Sol_cli_deployment_plan.services =
          List.map
            (fun (s : Sol_cli_deployment_plan.service_spec) ->
               { s with
                 consumes_kafka = true
               ; config = List.remove_assoc "SOL_KAFKA_DURABILITY" s.config
               })
            (plan_for "prod/aws/us-east-1").Sol_cli_deployment_plan.services
      }
    in
    let target = target_of (load "prod/aws/us-east-1") in
    match
      Pre.establish ~target ~apply_mode:Sol_cli_release.Direct ~plan P.Kafka_durability
    with
    | Pre.Unmet (Pre.Application, reason) ->
      check_bool
        "names the missing durability requirement"
        true
        (Sol_cli_string.contains ~needle:"SOL_KAFKA_DURABILITY" reason)
    | _ -> Alcotest.fail "expected an application finding for a consumer without it")
;;

let test_credential_posture_is_established () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    let plan = plan_for "prod/aws/us-east-1" in
    check_bool
      "the renderer guarantees no ambient Kubernetes credential"
      true
      (Pre.establish
         ~target:(target_of (load "prod/aws/us-east-1"))
         ~apply_mode:Sol_cli_release.Direct
         ~plan
         P.Credential_posture
       = Pre.Established))
;;

(* AUDIT-080: a declared node-failure-tolerant workload fails closed until the
   target declares enough headroom to restore its replicas. *)
let test_node_failure_tolerant_requires_headroom () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    let plan = node_failure_tolerant_plan "prod/aws/us-east-1" in
    let fs =
      findings (preflight ~plan ~apply_mode:Sol_cli_release.Direct "prod/aws/us-east-1")
    in
    match
      List.find_opt (fun (f : Pre.finding) -> f.capability = P.Workload_availability) fs
    with
    | None -> Alcotest.fail "expected a workload-availability finding"
    | Some f ->
      check_bool "target side" true (f.side = Pre.Target);
      check_bool
        "names the headroom declaration"
        true
        (Sol_cli_string.contains ~needle:"node_failure_headroom_nodes" f.reason))
;;

let test_node_failure_tolerant_established_with_headroom () =
  with_workspace (fun () ->
    write_target
      prod_aws
      "target:\n  profile: production-single-region\n  node_failure_headroom_nodes: 1\n";
    let plan = node_failure_tolerant_plan "prod/aws/us-east-1" in
    let fs =
      findings (preflight ~plan ~apply_mode:Sol_cli_release.Direct "prod/aws/us-east-1")
    in
    check_bool
      "declared headroom establishes the availability guarantee"
      false
      (List.exists (fun (f : Pre.finding) -> f.capability = P.Workload_availability) fs))
;;

let test_availability_rejects_one_replica () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    let message =
      availability_rejection
        charge_svc
        ~toml:"[infra.scale]\nreplicas = 1\navailability = \"node-failure-tolerant\"\n"
    in
    check_bool
      "names the supported alternative"
      true
      (Sol_cli_string.contains ~needle:"replicas = 2" message))
;;

let test_availability_rejects_a_function () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    let message =
      availability_rejection
        charge_fn
        ~toml:
          "[service]\n\
           schedule = \"0 3 * * *\"\n\n\
           [infra.scale]\n\
           availability = \"node-failure-tolerant\"\n"
    in
    check_bool
      "explains functions are scheduled jobs"
      true
      (Sol_cli_string.contains ~needle:"scheduled jobs" message))
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

let test_declared_kafka_resource_is_a_target_requirement () =
  (* INFRA-038. A workspace that declares a Kafka *resource* is stating that the
     target must provide Kafka durability -- a target-side requirement. It is not
     stating that every Service deployed onto that target uses Kafka. Those are
     different claims, and only the second belongs to a workload.

     This test previously asserted the opposite: that declaring the resource
     required a workload-side Kafka dependency to be declared. That is what made a
     stateless Service undeployable on a target whose profile supports Kafka. *)
  with_workspace (fun () ->
    write "sol.yml" "project: pluto\nresources:\n  events:\n    type: kafka\n";
    write_target prod_aws selecting;
    let fs =
      findings (preflight ~apply_mode:Sol_cli_release.Direct "prod/aws/us-east-1")
    in
    check_bool
      "no workload acquires a Kafka requirement from the target's capability"
      true
      (not
         (List.exists
            (fun (f : Pre.finding) ->
               f.capability = P.Kafka_durability && f.side = Pre.Application)
            fs)))
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
        (Sol_cli_string.contains ~needle:"resource" finding.reason))
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
    check_bool
      "says nothing changed"
      true
      (Sol_cli_string.contains ~needle:"Nothing was changed" report);
    check_bool
      "names the unmet guarantee"
      true
      (Sol_cli_string.contains
         ~needle:"immutable artifact identity is not established"
         report);
    check_bool
      "carries no ticket ids"
      false
      (List.exists
         (fun needle -> Sol_cli_string.contains ~needle report)
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

(* INFRA-030: the production profile's capacity contract. These pin the envelope
   and the recommended shape together, so shrinking the shape or growing the
   platform's declared requests fails the build instead of failing a live install
   the way HARDEN-002 Run 5 attempt 1 did. *)
let test_recommended_shape_satisfies_the_envelope () =
  let shape = P.recommended_node_shape in
  (match
     P.satisfies_capacity ~envelope:P.platform_capacity_envelope ~shape ~headroom_nodes:1
   with
   | Ok () -> ()
   | Error reason ->
     Alcotest.fail
       (Printf.sprintf
          "the profile's own recommended shape must satisfy its own capacity contract, \
           but it does not: %s"
          reason));
  (* And comfortably rather than barely: the platform must still fit after the
     one-node headroom a node-failure-tolerant workload requires, which is the
     margin attempt 1 did not have. *)
  check_bool
    "fits after headroom with margin"
    true
    ((shape.nodes - 1) * shape.vcpu_per_node > P.platform_capacity_envelope.platform_vcpu)
;;

let test_attempt_1_shape_is_rejected () =
  (* Exactly HARDEN-002 Run 5 attempt 1: three 2-vCPU nodes, which is what the
     provider root defaulted to while the profile declared nothing. *)
  let shape =
    { P.instance_type = "m6i.large"
    ; vcpu_per_node = 2
    ; memory_gib_per_node = 8
    ; nodes = 3
    }
  in
  let shortfalls =
    P.capacity_shortfall ~envelope:P.platform_capacity_envelope ~shape ~headroom_nodes:1
  in
  check_bool "Run 5 attempt 1's shape is rejected" true (shortfalls <> []);
  let joined = String.concat " " shortfalls in
  check_bool
    "names the per-node floor"
    true
    (Sol_cli_string.contains ~needle:"each node must offer at least 4 vCPU" joined);
  check_bool
    "names the post-headroom shortfall"
    true
    (Sol_cli_string.contains ~needle:"vCPU left after node-failure headroom" joined);
  check_bool
    "the error names the shape it refused"
    true
    (match
       P.satisfies_capacity
         ~envelope:P.platform_capacity_envelope
         ~shape
         ~headroom_nodes:1
     with
     | Ok () -> false
     | Error reason -> Sol_cli_string.contains ~needle:"m6i.large" reason)
;;

let test_headroom_that_leaves_nothing_is_rejected () =
  let shape = P.recommended_node_shape in
  let shortfalls =
    P.capacity_shortfall
      ~envelope:P.platform_capacity_envelope
      ~shape
      ~headroom_nodes:shape.nodes
  in
  check_bool
    "reserving every node is refused rather than silently accepted"
    true
    (Sol_cli_string.contains
       ~needle:"leaves no schedulable capacity at all"
       (String.concat " " shortfalls))
;;

let test_profile_target_pins_the_node_shape () =
  with_workspace (fun () ->
    write_target prod_aws selecting;
    let vars =
      match
        Sol_cli_terraform_vars.of_config ~workspace:"pluto" (load "prod/aws/us-east-1")
      with
      | Ok vars -> vars
      | Error e -> Alcotest.fail e
    in
    check_str
      "node instance types are profile-derived"
      "[\"m6i.xlarge\"]"
      (List.assoc "node_instance_types" vars);
    check_str "node count is profile-derived" "4" (List.assoc "node_desired_size" vars);
    (* Ordering is the enforcement: Terraform takes the last assignment, so the
       profile's value must come after the caller's. *)
    check_strs
      "the profile's value is applied after the caller's"
      [ "node_desired_size=2"; "node_desired_size=4" ]
      (Sol_cli_config.vars_with_profile_precedence
         ~has_profile:true
         ~cli_vars:[ "node_desired_size=2" ]
         ~config_vars:[ "node_desired_size=4" ]))
;;

let test_ordinary_target_keeps_its_own_shape () =
  with_workspace (fun () ->
    write_target prod_aws "target:\n  cluster_name: mine\n";
    let vars =
      match
        Sol_cli_terraform_vars.of_config ~workspace:"pluto" (load "prod/aws/us-east-1")
      with
      | Ok vars -> vars
      | Error e -> Alcotest.fail e
    in
    check_bool
      "an ordinary target makes no capacity claim and keeps full control"
      true
      (not (List.mem_assoc "node_instance_types" vars)))
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
        ; ( "stateless scope acquires no Kafka requirement"
          , `Quick
          , test_stateless_scope_acquires_no_kafka_requirement )
        ; ( "scope declaring Kafka is unaffected"
          , `Quick
          , test_scope_declaring_kafka_is_unaffected )
        ; ( "whole-workspace topic without declaration fails closed"
          , `Quick
          , test_whole_workspace_topic_without_declaration_fails_closed )
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
            "undeclared language is an application finding"
            `Quick
            test_undeclared_language_is_an_application_finding
        ; Alcotest.test_case
            "declared OCaml establishes the version guarantee"
            `Quick
            test_declared_ocaml_establishes_versions
        ; Alcotest.test_case
            "TypeScript is not qualified"
            `Quick
            test_typescript_is_not_qualified
        ; Alcotest.test_case
            "unqualified provider is a target finding"
            `Quick
            test_unqualified_provider_is_a_target_finding
        ; Alcotest.test_case "emit-to rejected" `Quick test_emit_to_rejected_for_profile
        ; Alcotest.test_case
            "node-failure-tolerant requires headroom"
            `Quick
            test_node_failure_tolerant_requires_headroom
        ; Alcotest.test_case
            "node-failure-tolerant established with headroom"
            `Quick
            test_node_failure_tolerant_established_with_headroom
        ; Alcotest.test_case
            "availability rejects one replica"
            `Quick
            test_availability_rejects_one_replica
        ; Alcotest.test_case
            "availability rejects a function"
            `Quick
            test_availability_rejects_a_function
        ; Alcotest.test_case
            "missing alert receiver is a target finding"
            `Quick
            test_missing_alert_receiver_is_a_target_finding
        ; Alcotest.test_case
            "complete alert contract establishes delivery"
            `Quick
            test_complete_alert_contract_establishes_delivery
        ; Alcotest.test_case
            "unroutable alert receiver is a target finding"
            `Quick
            test_unroutable_alert_receiver_is_a_target_finding
        ; Alcotest.test_case
            "durability established for a qualified target"
            `Quick
            test_durability_established_for_a_qualified_target
        ; Alcotest.test_case
            "durability fails closed for an unqualified provider"
            `Quick
            test_durability_fails_closed_for_an_unqualified_provider
        ; Alcotest.test_case
            "kafka durability requires the rendered requirement"
            `Quick
            test_kafka_durability_requires_the_rendered_requirement
        ; Alcotest.test_case
            "credential posture is established"
            `Quick
            test_credential_posture_is_established
        ; Alcotest.test_case
            "remote state requires a backend"
            `Quick
            test_remote_state_requires_a_backend
        ; Alcotest.test_case
            "remote state established by declaration"
            `Quick
            test_remote_state_established_by_declaration
        ; Alcotest.test_case
            "scoped identities require roles and cidr"
            `Quick
            test_scoped_identities_require_roles_and_cidr
        ; Alcotest.test_case
            "world-reachable endpoint is rejected"
            `Quick
            test_world_reachable_endpoint_is_rejected
        ; Alcotest.test_case
            "scoped identities established"
            `Quick
            test_scoped_identities_established
        ; Alcotest.test_case
            "declared Kafka resource is a target requirement"
            `Quick
            test_declared_kafka_resource_is_a_target_requirement
        ; Alcotest.test_case
            "Postgres resource declaration required"
            `Quick
            test_postgres_resource_declaration_required
        ; Alcotest.test_case
            "mutable tag is an application finding"
            `Quick
            test_mutable_tag_is_an_application_finding
        ; Alcotest.test_case
            "digest plan establishes the artifact guarantee"
            `Quick
            test_digest_plan_establishes_artifact_guarantee
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
    ; ( "platform capacity"
      , [ Alcotest.test_case
            "recommended shape satisfies the envelope"
            `Quick
            test_recommended_shape_satisfies_the_envelope
        ; Alcotest.test_case
            "Run 5 attempt 1's shape is rejected"
            `Quick
            test_attempt_1_shape_is_rejected
        ; Alcotest.test_case
            "headroom that leaves nothing is rejected"
            `Quick
            test_headroom_that_leaves_nothing_is_rejected
        ; Alcotest.test_case
            "a profile target pins the node shape"
            `Quick
            test_profile_target_pins_the_node_shape
        ; Alcotest.test_case
            "an ordinary target keeps its own shape"
            `Quick
            test_ordinary_target_keeps_its_own_shape
        ] )
    ]
;;
