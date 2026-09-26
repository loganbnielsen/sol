module L = Sol_cli_cloud_lifecycle

let provider = Sol_cli_provider.Aws

let target : Sol_cli_config.target =
  { name = "prod/aws/us-east-1"
  ; env = "prod"
  ; provider
  ; region = "us-east-1"
  ; registry = None
  ; base_domain = Some "acme.example"
  ; cluster_issuer = Some "letsencrypt-prod"
  ; letsencrypt_email = Some "ops@example.test"
  ; cluster_name = Some "acme-prod"
  ; kube_context = None
  ; kubeconfig = None
  ; terraform_var_file = None
  ; observability_backend = Some "self_hosted_durable"
  ; destroy_retention = None
  ; alert_receiver_type = None
  ; alert_receiver_url = None
  ; alert_owner = None
  ; alert_runbook_url = None
  ; state_bucket = Some "acme-state"
  ; cluster_endpoint_cidr = None
  ; node_failure_headroom_nodes = None
  ; profile = None
  ; provider_fields =
      [ ( "aws"
        , [ "state_lock_table", "acme-lock"
          ; "provisioner_role_arn", "arn:aws:iam::1:role/provisioner"
          ; "cluster_access_role_arn", "arn:aws:iam::1:role/cluster-access"
          ] )
      ]
  }
;;

(* REFAC-098: provider-native configuration lives in the provider's own block. *)
let without_aws_field key (t : Sol_cli_config.target) =
  { t with
    provider_fields =
      List.map
        (fun (provider, fields) ->
           if provider = "aws"
           then provider, List.remove_assoc key fields
           else provider, fields)
        t.provider_fields
  }
;;

let output ?(value = `String "x") name =
  name, `Assoc [ "sensitive", `Bool false; "value", value ]
;;

let valid_outputs () =
  `Assoc
    [ output "cluster_name" ~value:(`String "acme-prod")
    ; output "kubeconfig_command"
    ; output
        "cluster_access_role_arn"
        ~value:(`String "arn:aws:iam::1:role/cluster-access")
    ; output "cert_manager_irsa_arn" ~value:(`String "arn:aws:iam::1:role/cert-manager")
    ; output "loki_s3_bucket" ~value:(`String "loki")
    ; output "loki_irsa_arn" ~value:(`String "loki-role")
    ; output "thanos_s3_bucket" ~value:(`String "thanos")
    ; output "thanos_irsa_arn" ~value:(`String "thanos-role")
    ; output "grafana_irsa_arn" ~value:`Null
    ; output "managed_resource_dashboards" ~value:(`Assoc [])
    ]
;;

let parse json = Sol_cli_aws_cluster.aws_outputs_of_json (Yojson.Safe.to_string json)

let test_outputs () =
  (match parse (valid_outputs ()) with
   | Ok _ -> ()
   | Error message -> Alcotest.fail message);
  let missing =
    match valid_outputs () with
    | `Assoc fields -> `Assoc (List.remove_assoc "cluster_name" fields)
    | _ -> assert false
  in
  Alcotest.(check bool) "missing required" true (Result.is_error (parse missing));
  let wrong =
    match valid_outputs () with
    | `Assoc fields ->
      `Assoc
        (("cluster_name", `Assoc [ "value", `Int 1 ])
         :: List.remove_assoc "cluster_name" fields)
    | _ -> assert false
  in
  Alcotest.(check bool) "wrong type" true (Result.is_error (parse wrong))
;;

(* HARDEN-002 run 3, finding 10: `terraform output -json` OMITS an output whose
   value is null (v1.9.8). loki_*/thanos_* are null unless durable observability
   is enabled (the default), so a real target's output JSON simply has no such
   keys. The parser must treat an absent optional output like a null one instead
   of raising Type_error; a required output that is absent must still fail
   closed with a named error. *)
let test_outputs_absent_optional () =
  let optional =
    [ "loki_s3_bucket"
    ; "loki_irsa_arn"
    ; "thanos_s3_bucket"
    ; "thanos_irsa_arn"
    ; "grafana_irsa_arn"
    ]
  in
  let without_optional =
    match valid_outputs () with
    | `Assoc fields ->
      `Assoc (List.filter (fun (k, _) -> not (List.mem k optional)) fields)
    | _ -> assert false
  in
  (match parse without_optional with
   | Ok _ -> ()
   | Error message ->
     Alcotest.fail ("absent optional outputs must parse, not crash: " ^ message));
  let without_required =
    match without_optional with
    | `Assoc fields -> `Assoc (List.remove_assoc "cert_manager_irsa_arn" fields)
    | _ -> assert false
  in
  Alcotest.(check bool)
    "a missing required output still fails closed"
    true
    (Result.is_error (parse without_required))
;;

(* GCP's cloud root publishes a different set of facts -- a project and a region
   rather than a role ARN -- so it has its own type, its own parser, and its own
   required/optional split. The optional half matters for the same reason as AWS's:
   Terraform omits a null output entirely, so a target without durable
   observability has no `loki_*`/`thanos_*` keys at all. *)
let valid_gcp_outputs () =
  `Assoc
    [ output "cluster_name" ~value:(`String "sol-qual")
    ; output "project_id" ~value:(`String "sol-qualification")
    ; output "region" ~value:(`String "us-central1")
    ; output
        "artifact_registry"
        ~value:(`String "us-central1-docker.pkg.dev/sol-qualification/sol-qual")
    ; output
        "provisioner_service_account"
        ~value:(`String "sol-qual-provisioner@sol-qualification.iam.gserviceaccount.com")
    ; output "loki_gcs_bucket" ~value:`Null
    ; output "thanos_gcs_bucket" ~value:`Null
    ; output "loki_workload_identity_sa_email" ~value:`Null
    ; output "thanos_workload_identity_sa_email" ~value:`Null
    ]
;;

let parse_gcp json = Sol_cli_gcp_cluster.gcp_outputs_of_json (Yojson.Safe.to_string json)

let without_output name json =
  match json with
  | `Assoc fields -> `Assoc (List.remove_assoc name fields)
  | _ -> assert false
;;

let test_gcp_outputs () =
  (match parse_gcp (valid_gcp_outputs ()) with
   | Ok outputs ->
     Alcotest.(check string) "cluster" "sol-qual" outputs.Sol_cli_gcp_cluster.cluster_name;
     Alcotest.(check string)
       "project"
       "sol-qualification"
       outputs.Sol_cli_gcp_cluster.project_id;
     Alcotest.(check string) "region" "us-central1" outputs.Sol_cli_gcp_cluster.region;
     Alcotest.(check (option string)) "no loki bucket" None outputs.loki_gcs_bucket
   | Error message -> Alcotest.fail message);
  (* The project and region are contract, not incidental context: every GCP API
     call and the cluster credential are addressed through them. A GCP root that
     stopped publishing one must fail the lifecycle rather than leave Sol
     guessing which project it is about to wire the platform into. *)
  List.iter
    (fun name ->
       Alcotest.(check bool)
         (name ^ " is required")
         true
         (Result.is_error (parse_gcp (without_output name (valid_gcp_outputs ())))))
    [ "cluster_name"
    ; "project_id"
    ; "region"
    ; "artifact_registry"
    ; "provisioner_service_account"
    ];
  List.iter
    (fun name ->
       match parse_gcp (without_output name (valid_gcp_outputs ())) with
       | Ok _ -> ()
       | Error message -> Alcotest.fail ("absent optional " ^ name ^ ": " ^ message))
    [ "loki_gcs_bucket"
    ; "thanos_gcs_bucket"
    ; "loki_workload_identity_sa_email"
    ; "thanos_workload_identity_sa_email"
    ]
;;

(* The platform definition's variables are the *provider's*: passing AWS's set to a
   GCP root is an undeclared-variable error, and vice versa. So the mapping emits
   only the provider's own inputs, and a capability the provider cannot wire yet is
   refused rather than silently omitted. *)
let gcp_target () =
  { target with
    name = "prod/gcp/us-central1"
  ; provider = Sol_cli_provider.Gcp
  ; region = "us-central1"
  ; kube_context =
      Some "gke_sol-qualification_us-central1_sol"
      (* The base target names a ClusterIssuer; this one deliberately does not, so
       the plain case is the case under test. GCP cannot wire an issuer yet, and
       asking for one is asserted separately. *)
  ; cluster_issuer = None
  }
;;

(* REFAC-096: the identity check moved behind the cluster handle. The cloud root
   reports the role the platform root will act as; one that differs from the role
   the target declared must refuse the platform wiring, and the matching one must
   not (the positive control). *)
let test_cluster_identity_check () =
  let aws_target = Result.get_ok (L.cloud_target target) in
  let cluster role =
    let outputs =
      match valid_outputs () with
      | `Assoc fields ->
        `Assoc
          (("cluster_access_role_arn", `Assoc [ "value", `String role ])
           :: List.remove_assoc "cluster_access_role_arn" fields)
      | _ -> assert false
    in
    Sol_cli_aws_cluster.cluster
      ~region:"us-east-1"
      ~provisioner_role_arn:None
      (Result.get_ok (parse outputs))
  in
  Alcotest.(check bool)
    "a different role is refused"
    true
    (Result.is_error
       (L.platform_inputs aws_target (cluster "arn:aws:iam::1:role/somebody-else")));
  Alcotest.(check bool)
    "the declared role is accepted"
    true
    (Result.is_ok
       (L.platform_inputs aws_target (cluster "arn:aws:iam::1:role/cluster-access")))
;;

let test_platform_terraform_vars () =
  let vars inputs =
    match L.platform_terraform_vars inputs with
    | Ok vars -> vars
    | Error message -> Alcotest.fail message
  in
  let has vars entry = List.mem entry vars in
  let prefixed vars prefix =
    List.filter (fun entry -> String.starts_with ~prefix entry) vars
  in
  let aws_cloud =
    Sol_cli_aws_cluster.cluster
      ~region:"us-east-1"
      ~provisioner_role_arn:None
      (Result.get_ok (parse (valid_outputs ())))
  in
  let aws_target = Result.get_ok (L.cloud_target target) in
  let aws_inputs = Result.get_ok (L.platform_inputs aws_target aws_cloud) in
  let aws = vars aws_inputs in
  Alcotest.(check bool) "AWS selects its own provider" true (has aws "cloud_provider=aws");
  Alcotest.(check bool) "AWS passes its region" true (has aws "aws_region=us-east-1");
  Alcotest.(check bool)
    "AWS passes the cert-manager role its issuer branch reads"
    true
    (has aws "cert_manager_irsa_role_arn=arn:aws:iam::1:role/cert-manager");
  Alcotest.(check (list string))
    "AWS passes no GCS inputs to a root that does not declare them"
    []
    (prefixed aws "loki_gcs_bucket=" @ prefixed aws "thanos_gcs_bucket=");
  let gcp = Result.get_ok (L.cloud_target (gcp_target ())) in
  let gcp_cloud =
    Sol_cli_gcp_cluster.cluster
      ~region:"us-central1"
      (Result.get_ok (parse_gcp (valid_gcp_outputs ())))
  in
  let gcp_inputs = Result.get_ok (L.platform_inputs gcp gcp_cloud) in
  let gcp_vars = vars gcp_inputs in
  Alcotest.(check bool)
    "GCP selects its own provider"
    true
    (has gcp_vars "cloud_provider=gcp");
  Alcotest.(check bool)
    "GCP names the StorageClass it adopts"
    true
    (has gcp_vars "storage_class_name=standard-rwo");
  Alcotest.(check bool)
    "GCP passes no AWS inputs to a root that does not declare them"
    true
    (prefixed gcp_vars "aws_region="
     @ prefixed gcp_vars "cert_manager_irsa_role_arn="
     @ prefixed gcp_vars "loki_s3_bucket="
     @ prefixed gcp_vars "grafana_irsa_role_arn="
     = []);
  (* TLS is the capability GCP cannot wire yet, and asking for it must be refused
     with the gap named rather than quietly omitting the issuer. A target that does
     not ask for it still gets a usable platform. *)
  let tls_target = { (gcp_target ()) with cluster_issuer = Some "letsencrypt-prod" } in
  let tls_cloud = Result.get_ok (L.cloud_target tls_target) in
  match L.platform_inputs tls_cloud gcp_cloud |> Result.map L.platform_terraform_vars with
  | Ok (Error message) ->
    Alcotest.(check bool)
      "the refusal names the missing solver"
      true
      (String.starts_with ~prefix:"this GCP target declares cluster_issuer" message)
  | Ok (Ok _) -> Alcotest.fail "a GCP target asking for TLS must be refused"
  | Error message -> Alcotest.fail message
;;

(* FND-0030 / DEC-033: the preparation declares the consequence of its own failure. An
   ordinary failure preserves the reason and lets destruction be attempted; a failure that
   stands for a declared retention guarantee blocks, and says why. Both directions are
   asserted here so neither can drift into the other. *)
let test_preparation_failure_policies () =
  let open L in
  let ordinary =
    Preparation_failed
      { reason = "guard-lowering apply exited 1"; policy = Continue_to_destroy }
  in
  let required =
    Preparation_failed
      { reason = "final snapshot could not be prepared"; policy = Block_destroy }
  in
  Alcotest.(check (option string))
    "an ordinary failure is reported"
    (Some "guard-lowering apply exited 1")
    (preparation_failure ordinary);
  Alcotest.(check (option string))
    "and it does NOT block destruction"
    None
    (destruction_blocked ordinary);
  Alcotest.(check (option string))
    "a required-preparation failure is reported"
    (Some "final snapshot could not be prepared")
    (preparation_failure required);
  Alcotest.(check (option string))
    "and it blocks, with the reason the target's own guarantee gives"
    (Some "final snapshot could not be prepared")
    (destruction_blocked required);
  Alcotest.(check (option string))
    "nothing to prepare never blocks"
    None
    (destruction_blocked Nothing_to_prepare);
  Alcotest.(check (option string))
    "a success never blocks"
    None
    (destruction_blocked (Prepared "snap-1"));
  Alcotest.(check (option string))
    "a success is not a failure"
    None
    (preparation_failure (Prepared "snap-1"))
;;

(* FND-0030: the destructive preparation targets only what state already represents, so a
   half-built target cannot be made to create the resource it was asked to remove. This is
   the property, not the mechanism: eligibility is configuration INTERSECT state. *)
let test_preparations_eligible () =
  let desired =
    [ "google_sql_database_instance.postgres"; "google_container_cluster.main" ]
  in
  let eligible state = L.preparations_eligible ~state ~desired in
  Alcotest.(check (list string))
    "both represented: both are eligible"
    desired
    (eligible desired);
  Alcotest.(check (list string))
    "the half-built case: the cluster exists in the provider but not in state, so it is \
     NOT prepared -- preparing it would create it"
    [ "google_sql_database_instance.postgres" ]
    (eligible [ "google_sql_database_instance.postgres" ]);
  Alcotest.(check (list string))
    "nothing represented: nothing to prepare"
    []
    (eligible []);
  Alcotest.(check (list string))
    "state that holds neither of the desired resources yields nothing"
    []
    (eligible [ "aws_db_instance.postgres" ]);
  Alcotest.(check (list string))
    "order follows the configuration, not the state"
    desired
    (eligible (List.rev desired));
  (* The other half of the same read: what a destroy CANNOT reach. Terraform destroys what
     its state knows about, so these can survive it -- the Attempt-6 cluster, still
     billable. Reporting them is why this exists. *)
  Alcotest.(check (list string))
    "the unrepresented set is the complement of the eligible one"
    [ "google_container_cluster.main" ]
    (L.preparations_unrepresented
       ~state:[ "google_sql_database_instance.postgres" ]
       ~desired);
  Alcotest.(check (list string))
    "nothing unrepresented when state holds everything"
    []
    (L.preparations_unrepresented ~state:desired ~desired);
  Alcotest.(check (list string))
    "everything is unrepresented when state holds nothing"
    desired
    (L.preparations_unrepresented ~state:[] ~desired)
;;

(* INFRA-067 / FND-0029: the refusal above is an INSTALL-time capability guarantee, so
   it belongs to installation. Evaluating it while computing the DESTRUCTION variables
   refused a target that `apply` had already accepted and created, which left billable
   infrastructure with no supported way to remove it until the target declaration was
   edited by hand. Both directions are asserted together so neither can drift:
   installation still refuses, destruction must not. *)
let test_platform_vars_destruction_context () =
  let tls_target = { (gcp_target ()) with cluster_issuer = Some "letsencrypt-prod" } in
  let tls_cloud = Result.get_ok (L.cloud_target tls_target) in
  let gcp_cloud =
    Sol_cli_gcp_cluster.cluster
      ~region:"us-central1"
      (Result.get_ok (parse_gcp (valid_gcp_outputs ())))
  in
  let inputs = Result.get_ok (L.platform_inputs tls_cloud gcp_cloud) in
  (match L.platform_terraform_vars inputs with
   | Error message ->
     Alcotest.(check bool)
       "installation still refuses a GCP target asking for TLS"
       true
       (String.starts_with ~prefix:"this GCP target declares cluster_issuer" message)
   | Ok _ -> Alcotest.fail "installation must still refuse a GCP target asking for TLS");
  match L.platform_terraform_vars ~context:L.Destruction inputs with
  | Ok vars ->
    Alcotest.(check bool)
      "destruction gets the variables it needs to remove the platform"
      true
      (List.mem "cluster_issuer=letsencrypt-prod" vars)
  | Error message ->
    Alcotest.fail
      ("destruction must not be refused by an install-time requirement: " ^ message)
;;

(* HARDEN-002 run 4, finding 12: the base providers (hashicorp/kubernetes,
   hashicorp/helm) resolve the kubeconfig from KUBE_CONFIG_PATH/KUBE_CONFIG_PATHS,
   not KUBECONFIG. Every name must point at the ephemeral provisioner kubeconfig,
   or the platform phase silently uses the ambient ~/.kube/config. *)
let test_provisioner_kube_env () =
  let path = "/tmp/sol-platform-provisioner-test.kubeconfig" in
  let env = Sol_cli_cluster.provisioner_kube_env path in
  List.iter
    (fun key -> Alcotest.(check (option string)) key (Some path) (List.assoc_opt key env))
    [ "KUBECONFIG"; "KUBE_CONFIG_PATH"; "KUBE_CONFIG_PATHS" ]
;;

(* HARDEN-002 run 4 / ADR 0003: the lifecycle phase decides the authority and the
   desired-state policy. These assert the transitions and the policy edges --
   in particular that a verified PreparingDestroy can never be followed by a
   Ready-policy reconciliation (finding 15), and that destroy policy contradicts
   the production RDS-deletion-protection invariant by design. *)
let test_lifecycle_phases () =
  let open L in
  (* The model owns the operator-facing names, so a test label cannot drift from
     what an operator is actually told. *)
  let name = phase_to_string in
  Alcotest.(check bool)
    "PlatformInstalling uses Installation policy"
    true
    (policy_of_phase Platform_installing = Installation);
  Alcotest.(check bool)
    "Ready uses Production policy"
    true
    (policy_of_phase Ready = Production);
  Alcotest.(check bool)
    "PreparingDestroy uses Destroy policy"
    true
    (policy_of_phase Preparing_destroy = Destroy);
  Alcotest.(check bool) "Ready policy applies in Ready" true (ready_policy_applies Ready);
  List.iter
    (fun p ->
       Alcotest.(check bool)
         (name p ^ " is not Ready policy")
         false
         (ready_policy_applies p))
    [ Absent
    ; Cloud_bootstrap
    ; Platform_installing
    ; Platform_updating
    ; Preparing_destroy
    ; Destroying
    ];
  List.iter
    (fun (from, to_) ->
       Alcotest.(check bool)
         (name from ^ " -> " ^ name to_ ^ " is legal")
         true
         (transition_allowed ~from ~to_))
    [ Absent, Cloud_bootstrap
    ; Cloud_bootstrap, Platform_installing
    ; Platform_installing, Ready
    ; Ready, Platform_updating
    ; Platform_updating, Ready
    ; Ready, Preparing_destroy
    ; Preparing_destroy, Destroying
    ; Destroying, Absent
    ];
  List.iter
    (fun (from, to_) ->
       Alcotest.(check bool)
         (name from ^ " -> " ^ name to_ ^ " is rejected")
         false
         (transition_allowed ~from ~to_))
    [ Preparing_destroy, Ready
    ; Preparing_destroy, Platform_installing
    ; Destroying, Preparing_destroy
    ; Destroying, Ready
    ; Ready, Platform_installing
    ; Absent, Ready
    ; Cloud_bootstrap, Ready
    ; Platform_installing, Preparing_destroy
    ];
  (* The abort edge (ADR 0003 invariant 6). Destruction is not a forward
     transition, so the relation above is right to reject
     `Platform_installing -> Preparing_destroy` -- teardown is a different class of
     move, and the two must not be folded together or the relation stops meaning
     "the diagram". What matters is that the abort edge admits it, so a failed or
     partially installed target can never be stranded. *)
  Alcotest.(check bool)
    "the forward relation still rejects PlatformInstalling -> PreparingDestroy"
    false
    (transition_allowed ~from:Platform_installing ~to_:Preparing_destroy);
  List.iter
    (fun phase ->
       Alcotest.(check bool)
         (name phase ^ " admits destruction")
         (phase <> Absent)
         (destruction_available phase);
       Alcotest.(check string)
         (name phase ^ " enters destruction as expected")
         (if phase = Absent then "Absent" else "PreparingDestroy")
         (phase_to_string (enter_destruction ~from:phase)))
    [ Absent
    ; Cloud_bootstrap
    ; Platform_installing
    ; Ready
    ; Platform_updating
    ; Preparing_destroy
    ; Destroying
    ];
  (* A destroy never lands in a phase whose policy is Ready, which is what makes
     invariant 4 hold at the decision point rather than only after re-verification
     (finding 15). *)
  List.iter
    (fun phase ->
       Alcotest.(check bool)
         (name phase ^ " does not enter a Ready-policy phase by destroying")
         false
         (ready_policy_applies (enter_destruction ~from:phase)))
    [ Absent
    ; Cloud_bootstrap
    ; Platform_installing
    ; Ready
    ; Platform_updating
    ; Preparing_destroy
    ; Destroying
    ];
  let destroy_vars =
    policy_vars
      ~provider:Sol_cli_provider.Aws
      ~phase:Preparing_destroy
      ~destroy_snapshot_id:"snap-1"
      ~retention:default_destroy_retention
  in
  Alcotest.(check (option string))
    "destroy policy disables RDS deletion protection"
    (Some "false")
    (List.assoc_opt "rds_deletion_protection" destroy_vars);
  Alcotest.(check (option string))
    "destroy policy carries the prepared final snapshot"
    (Some "snap-1")
    (List.assoc_opt "rds_final_snapshot_identifier" destroy_vars);
  Alcotest.(check int)
    "destroy policy is exactly the three destroy vars"
    3
    (List.length destroy_vars);
  (* The GCP policy carries GCP's guards and none of AWS's: `-var` for a variable a
     root does not declare is an error, so inheriting AWS's would have failed the
     first GCP destroy on an undeclared variable instead of lifting anything.

     Both of GCP's guards, and the second was found live: the GKE cluster's
     provider-level `deletion_protection` defaults to true, so a policy that lifted
     only Cloud SQL left a target that could not be destroyed at all ("Cannot
     destroy cluster because deletion_protection is set to true"). Neither entry is
     retention -- that is DEC-033's separate axis, and on GCP it is not expressible
     yet. *)
  Alcotest.(check (list string))
    "the GCP destroy policy carries both of GCP's guards"
    [ "sql_deletion_protection"; "false"; "gke_deletion_protection"; "false" ]
    (List.concat_map
       (fun (k, v) -> [ k; v ])
       (policy_vars
          ~provider:Sol_cli_provider.Gcp
          ~phase:Preparing_destroy
          ~destroy_snapshot_id:"snap-1"
          ~retention:default_destroy_retention));
  Alcotest.(check int)
    "Ready adds no policy overrides"
    0
    (List.length
       (policy_vars
          ~provider:Sol_cli_provider.Aws
          ~phase:Ready
          ~destroy_snapshot_id:"x"
          ~retention:default_destroy_retention));
  Alcotest.(check int)
    "GCP Ready adds no policy overrides either"
    0
    (List.length
       (policy_vars
          ~provider:Sol_cli_provider.Gcp
          ~phase:Ready
          ~destroy_snapshot_id:"x"
          ~retention:default_destroy_retention));
  (* ADR 0003: the phase is recomputed from observation on every run, never
     persisted and never infrastructure truth. *)
  Alcotest.(check string)
    "no substrate observes as Absent"
    "Absent"
    (phase_to_string (observed_phase ~cloud_exists:false ~platform_installed:false));
  Alcotest.(check string)
    "an absent substrate observes as Absent whatever else is claimed"
    "Absent"
    (phase_to_string (observed_phase ~cloud_exists:false ~platform_installed:true));
  Alcotest.(check string)
    "an uninstalled platform observes as PlatformInstalling"
    "PlatformInstalling"
    (phase_to_string (observed_phase ~cloud_exists:true ~platform_installed:false));
  Alcotest.(check string)
    "a completed install observes as Ready"
    "Ready"
    (phase_to_string (observed_phase ~cloud_exists:true ~platform_installed:true));
  (* The operation may only move along edges the relation admits. This is the
     disagreement that used to exist: the relation rejected
     Ready -> PlatformInstalling while `sol cloud apply` performed exactly that
     on an already-Ready target. *)
  Alcotest.(check bool)
    "PlatformInstalling -> Ready is admitted"
    true
    (Result.is_ok (enter ~from:Platform_installing ~to_:Ready));
  Alcotest.(check bool)
    "Ready -> PlatformUpdating is admitted"
    true
    (Result.is_ok (enter ~from:Ready ~to_:Platform_updating));
  Alcotest.(check bool)
    "PlatformUpdating -> Ready is admitted"
    true
    (Result.is_ok (enter ~from:Platform_updating ~to_:Ready));
  Alcotest.(check bool)
    "Ready -> PlatformInstalling is refused"
    true
    (Result.is_error (enter ~from:Ready ~to_:Platform_installing));
  Alcotest.(check bool)
    "PreparingDestroy -> Ready is refused"
    true
    (Result.is_error (enter ~from:Preparing_destroy ~to_:Ready));
  Alcotest.(check bool)
    "CloudBootstrap -> Ready is refused (the install is not skippable)"
    true
    (Result.is_error (enter ~from:Cloud_bootstrap ~to_:Ready));
  Alcotest.(check string)
    "a refused transition names both phases"
    "illegal lifecycle transition Ready -> PlatformInstalling"
    (Result.get_error (enter ~from:Ready ~to_:Platform_installing))
;;

let test_backends () =
  let get t root = Result.get_ok (L.backend_config t ~root) in
  let cloud = get target `Cloud
  and platform = get target `Platform in
  Alcotest.(check bool) "distinct" true (cloud <> platform);
  Alcotest.(check bool)
    "cloud key"
    true
    (List.mem "key=sol/prod/aws/us-east-1/cloud.tfstate" cloud);
  Alcotest.(check bool)
    "platform key"
    true
    (List.mem "key=sol/prod/aws/us-east-1/platform.tfstate" platform);
  (* S3 has no native locking, so the lock resource is part of the AWS config and
     its absence is a refusal rather than a silent concurrent-apply hazard. *)
  let aws_without_lock = without_aws_field "state_lock_table" target in
  (match L.backend_config aws_without_lock ~root:`Cloud with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "an AWS target without a lock table must be refused");
  (* GCS locks natively: there is no resource to name, the object is addressed by
     `prefix`, and a target that declares a lock table for some other tool is not
     thereby invalid. *)
  let gcp =
    { target with
      name = "prod/gcp/us-central1"
    ; provider = Sol_cli_provider.Gcp
    ; region = "us-central1"
    ; kube_context = Some "gke_sol-qualification_us-central1_sol"
    }
  in
  let gcp_cloud = get gcp `Cloud in
  Alcotest.(check (list string))
    "GCS addresses the object by prefix and names no lock resource"
    [ "bucket=acme-state"; "prefix=sol/prod/gcp/us-central1/cloud.tfstate" ]
    gcp_cloud;
  Alcotest.(check bool)
    "GCS platform state is its own object"
    true
    (get gcp `Platform
     = [ "bucket=acme-state"; "prefix=sol/prod/gcp/us-central1/platform.tfstate" ]);
  (match
     L.backend_config
       { gcp with provider_fields = [ "gcp", [ "state_lock_table", "unnecessary" ] ] }
       ~root:`Cloud
   with
   | Ok config ->
     Alcotest.(check (list string))
       "a GCP target's lock table is not a backend attribute at all"
       [ "bucket=acme-state"; "prefix=sol/prod/gcp/us-central1/cloud.tfstate" ]
       config
   | Error message -> Alcotest.fail ("a GCP lock table must not be an error: " ^ message));
  (* The durable-state prerequisite is the same for both providers. *)
  List.iter
    (fun t ->
       match L.backend_config { t with state_bucket = None } ~root:`Cloud with
       | Error _ -> ()
       | Ok _ -> Alcotest.fail "a target without a state bucket must be refused")
    [ target; gcp ]
;;

(* The two providers' targets are not the same shape, and the difference is real
   rather than cosmetic: AWS names a role ARN because that is how a caller assumes
   the provisioner there, while GCP names nothing because the caller impersonates a
   service account through short-lived credentials. Requiring both to carry a
   role-shaped field would invent a concept GCP does not have. *)
let test_cloud_target () =
  let gcp =
    { target with
      name = "prod/gcp/us-central1"
    ; provider = Sol_cli_provider.Gcp
    ; region = "us-central1"
    ; kube_context = Some "gke_sol-qualification_us-central1_sol"
    }
  in
  let aws = Result.get_ok (L.cloud_target target) in
  Alcotest.(check bool)
    "AWS carries the provisioner role it must assume"
    true
    (aws.cluster_access_role_arn = Some "arn:aws:iam::1:role/cluster-access");
  let gcp = Result.get_ok (L.cloud_target gcp) in
  Alcotest.(check bool)
    "GCP carries no role ARN and is not refused for it"
    true
    (gcp.cluster_access_role_arn = None);
  Alcotest.(check string) "region travels from the target" "us-central1" gcp.target.region;
  Alcotest.(check (list string))
    "the target's own backends are the ones selected"
    [ "bucket=acme-state"; "prefix=sol/prod/gcp/us-central1/platform.tfstate" ]
    gcp.platform_backend;
  (match L.cloud_target (without_aws_field "cluster_access_role_arn" target) with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "an AWS target without a cluster-access role must be refused");
  match L.cloud_target { target with base_domain = None } with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "a target without a base domain must be refused"
;;

(* REFAC-100 / DEC-046 rule 4: every provider reaches the shared platform module
   through its own thin root, so the root and the address prefix are one rule. *)
let test_platform_root_selection () =
  Alcotest.(check string)
    "AWS has a root that declares the S3 backend"
    "platform/cloud/aws/platform"
    (L.platform_root Sol_cli_provider.Aws);
  Alcotest.(check string)
    "GCP has a root that declares the GCS backend"
    "platform/cloud/gcp/platform"
    (L.platform_root Sol_cli_provider.Gcp);
  Alcotest.(check string)
    "an address goes through the module that reaches the definition"
    "module.platform.kubernetes_namespace.cert_manager"
    (L.platform_address "kubernetes_namespace.cert_manager");
  Alcotest.(check bool)
    "the two providers do not select the same platform root"
    true
    (L.platform_root Sol_cli_provider.Aws <> L.platform_root Sol_cli_provider.Gcp)
;;

let test_deferred () =
  let open L in
  (match
     platform_plan_phases
       ~cluster_exists:false
       ~rbac_established:false
       ~crds_established:false
   with
   | Deferred _, Deferred _ -> ()
   | _ -> Alcotest.fail "fresh target must defer both platform phases");
  (match
     platform_plan_phases
       ~cluster_exists:true
       ~rbac_established:false
       ~crds_established:false
   with
   | Deferred _, Deferred _ -> ()
   | _ -> Alcotest.fail "a cluster without provisioner RBAC must defer both phases");
  (match
     platform_plan_phases
       ~cluster_exists:true
       ~rbac_established:true
       ~crds_established:false
   with
   | Plannable, Deferred _ -> ()
   | _ -> Alcotest.fail "existing cluster must plan prerequisites only");
  match
    platform_plan_phases
      ~cluster_exists:true
      ~rbac_established:true
      ~crds_established:true
  with
  | Plannable, Plannable -> ()
  | _ -> Alcotest.fail "fully established cluster must plan both phases"
;;

(* The fake cluster every readiness test reads. It answers the convergence checks
   with the shape they parse, so a check's own predicate is what is under test
   rather than the fake agreeing with it. The storage answer is derived from the
   provider's contract rather than spelled out, so the baseline stays "this
   cluster is converged for this provider". *)
let converged_cluster provider =
  let { L.storage_class; csi_driver } = L.platform_storage provider in
  function
  | "get" :: "storageclass" :: _ ->
    Some (Printf.sprintf "%s|%s|true " storage_class csi_driver)
  | "get" :: "service/ingress-nginx-controller" :: _ -> Some "example.elb.amazonaws.com"
  | "get" :: "daemonset" :: _ -> Some "4/4 4/4 "
  | "get" :: "statefulset" :: _ -> Some "3/3 1/1 "
  | "get" :: "pvc" :: _ -> Some "Bound Bound "
  | "get" :: "nodes" :: _ -> Some "True True "
  | _ -> Some ""
;;

let test_readiness_fails_each_predicate () =
  List.iter
    (fun p ->
       let succeeds = converged_cluster p in
       let all = L.readiness ~provider:p ~run:succeeds in
       Alcotest.(check string)
         (Printf.sprintf "baseline (%s)" (Sol_cli_provider.to_string p))
         "Ready"
         (L.readiness_summary all);
       List.iteri
         (fun failed _ ->
            let index = ref (-1) in
            let checks =
              L.readiness ~provider:p ~run:(fun argv ->
                incr index;
                if !index = failed then None else succeeds argv)
            in
            Alcotest.(check bool)
              (Printf.sprintf
                 "predicate %d fails closed (%s)"
                 failed
                 (Sol_cli_provider.to_string p))
              true
              (L.readiness_summary checks <> "Ready"))
         all)
    Sol_cli_provider.all
;;

let readiness_with_storage ~provider storage_output =
  L.readiness ~provider ~run:(fun argv ->
    match argv with
    | "get" :: "storageclass" :: _ -> Some storage_output
    | other -> converged_cluster provider other)
  |> L.readiness_summary
;;

(* The storage assertion is the one readiness predicate that is the provider's
   rather than Sol's, so the ways it could pass vacuously or leak across
   providers are what these pin. Two of them are states a real cluster actually
   reaches: no default class at all (EKS ships none, and Sol's own class is
   absent whenever `create_storage_class = false`), and *two* default classes
   (what a GCP cluster would have if Sol created its own on top of GKE's). *)
let test_storage_contract_is_provider_specific () =
  let aws = Sol_cli_provider.Aws in
  let gcp = Sol_cli_provider.Gcp in
  let check_ready provider label output =
    Alcotest.(check string) label "Ready" (readiness_with_storage ~provider output)
  in
  let check_unmet provider label output =
    Alcotest.(check bool) label true (readiness_with_storage ~provider output <> "Ready")
  in
  check_ready
    aws
    "the AWS contract is satisfied by gp3 on EBS CSI"
    "gp3|ebs.csi.aws.com|true ";
  check_ready
    gcp
    "the GCP contract is satisfied by GKE's default class"
    "standard-rwo|pd.csi.storage.gke.io|true ";
  check_unmet aws "no default StorageClass is unmet" "gp3|ebs.csi.aws.com|false ";
  check_unmet aws "a default class is unmet" "gp3|ebs.csi.aws.com|";
  check_unmet aws "an empty listing is unmet" "";
  check_unmet
    aws
    "two default classes are unmet, not resolved arbitrarily"
    "gp3|ebs.csi.aws.com|true gp2|ebs.csi.aws.com|true ";
  check_unmet
    aws
    "a default class Sol did not establish is unmet even on the same driver"
    "some-other-class|ebs.csi.aws.com|true ";
  check_unmet
    aws
    "the GCP provider's class does not satisfy the AWS contract"
    "standard-rwo|pd.csi.storage.gke.io|true ";
  check_unmet
    gcp
    "the AWS provider's class does not satisfy the GCP contract"
    "gp3|ebs.csi.aws.com|true "
;;

(* The invocations are per provider too: a storage check that named the other
   provider's driver would be answered by a cluster that is wrong for this
   target. CI validates each provider's argv against kubectl, so the two sets
   have to exist and stay the same shape. *)
let test_readiness_invocations_are_provider_specific () =
  let aws = L.readiness_invocations ~provider:Sol_cli_provider.Aws in
  let gcp = L.readiness_invocations ~provider:Sol_cli_provider.Gcp in
  let mentions needle checks =
    List.exists (fun (_, argv) -> List.exists (fun arg -> arg = needle) argv) checks
  in
  Alcotest.(check bool)
    "AWS asserts the EBS CSI driver"
    true
    (mentions "csidriver/ebs.csi.aws.com" aws);
  Alcotest.(check bool)
    "GCP asserts the PD CSI driver"
    true
    (mentions "csidriver/pd.csi.storage.gke.io" gcp);
  Alcotest.(check bool)
    "AWS does not assert the GCP driver"
    false
    (mentions "csidriver/pd.csi.storage.gke.io" aws);
  Alcotest.(check bool)
    "GCP does not assert the AWS driver"
    false
    (mentions "csidriver/ebs.csi.aws.com" gcp);
  Alcotest.(check int)
    "both providers assert the same number of checks"
    (List.length aws)
    (List.length gcp)
;;

(* The convergence predicates decide whether `sol cloud apply` may report [Ready],
   so the ways they could pass vacuously are worth pinning: an empty listing, and
   a listing that says nothing useful. DaemonSets additionally require a desired
   count — zero means the node set matched nothing — while StatefulSets do not,
   because their replicas are declared by their owner. *)
(* DEC-033: a destroy states what it deliberately keeps. The default must remain
   retain -- a disposable target opting out is a choice, not a change to what
   destroy promises for every target -- and an unparseable mode must be refused
   rather than quietly falling back to it. *)
let test_destroy_retention () =
  let destroy_vars retention =
    L.policy_vars
      ~provider:Sol_cli_provider.Aws
      ~phase:L.Preparing_destroy
      ~destroy_snapshot_id:"snap-1"
      ~retention
  in
  let round_trip raw =
    Result.map L.destroy_retention_to_string (L.destroy_retention_of_string raw)
  in
  Alcotest.(check (result string string))
    "final-snapshot parses"
    (Ok "final-snapshot")
    (round_trip "final-snapshot");
  Alcotest.(check (result string string)) "none parses" (Ok "none") (round_trip "none");
  Alcotest.(check bool)
    "an unknown mode is refused rather than defaulted"
    true
    (Result.is_error (L.destroy_retention_of_string "keep-everything"));
  Alcotest.(check bool)
    "the default retains a final snapshot"
    true
    (List.mem_assoc
       "rds_final_snapshot_identifier"
       (destroy_vars L.Retain_final_snapshot));
  Alcotest.(check bool)
    "retaining nothing passes no snapshot identity"
    true
    (List.assoc_opt "rds_final_snapshot_identifier" (destroy_vars L.Retain_nothing) = None);
  Alcotest.(check bool)
    "retaining nothing skips the final snapshot"
    true
    (List.assoc_opt "rds_skip_final_snapshot" (destroy_vars L.Retain_nothing)
     = Some "true");
  Alcotest.(check bool)
    "retention still lifts deletion protection either way"
    true
    (List.assoc_opt "rds_deletion_protection" (destroy_vars L.Retain_nothing)
     = Some "false")
;;

(* HARDEN-004 step 5 / FND-0046: the two assertions that used to live here pinned
   [retention_report]'s *policy* text -- including "no residual billable
   artifacts", which nothing observed. Retention reporting is now evidence-driven
   and is pinned in `test_destroy_verification.ml` instead. *)

let test_convergence_predicates () =
  let summary_with kind output =
    L.readiness ~provider ~run:(fun argv ->
      match argv with
      | "get" :: listed :: _ when listed = kind -> Some output
      | other -> converged_cluster provider other)
    |> L.readiness_summary
  in
  let check_ready label summary = Alcotest.(check string) label "Ready" summary in
  let check_unmet label summary = Alcotest.(check bool) label true (summary <> "Ready") in
  check_ready
    "every daemonset pod scheduled and ready"
    (summary_with "daemonset" "4/4 4/4 ");
  check_unmet
    "a daemonset short of its desired pods is unmet"
    (summary_with "daemonset" "4/4 3/4 ");
  check_unmet
    "a daemonset scheduling no pods is not converged"
    (summary_with "daemonset" "0/0 ");
  check_unmet "no daemonsets at all is unmet" (summary_with "daemonset" "");
  check_ready
    "every statefulset replica declared and ready"
    (summary_with "statefulset" "3/3 1/1 ");
  check_unmet
    "a statefulset short of its declared replicas is unmet"
    (summary_with "statefulset" "3/2 ");
  check_ready
    "a statefulset declared at zero replicas is its owner's choice"
    (summary_with "statefulset" "0/0 ");
  check_unmet "no statefulsets at all is unmet" (summary_with "statefulset" "");
  check_ready "every PVC bound" (summary_with "pvc" "Bound Bound ");
  check_unmet "a Pending PVC is unmet" (summary_with "pvc" "Bound Pending ");
  check_unmet "no PVCs at all is unmet" (summary_with "pvc" "");
  check_ready "every node Ready" (summary_with "nodes" "True True ");
  check_unmet "a NotReady node is unmet" (summary_with "nodes" "True False ");
  check_unmet "no nodes at all is unmet" (summary_with "nodes" "")
;;

(* The capability probes are typed now, so a test names both the capability and the
   three-valued answer instead of a bare bool that conflated "denied" with "the probe
   could not tell". *)
let capability verb resource = { Sol_cli_cloud_lifecycle.verb; resource }
let permitted capability = capability, Sol_cli_cloud_lifecycle.Permitted
let denied capability = capability, Sol_cli_cloud_lifecycle.Denied
let indeterminate capability why = capability, Sol_cli_cloud_lifecycle.Indeterminate why

(* DEC-040: the classifier is where the fail-open lived, and a shell stub cannot produce
   every case by hand (`no - reason`, a token/exit mismatch). It is pure, so it is tested
   directly rather than only through the harness. *)
let test_can_i_classification () =
  let classify ?(stderr = "") ~exit_code stdout =
    Sol_cli_cloud_lifecycle.capability_answer_of_can_i_output ~exit_code ~stdout ~stderr
  in
  let label = function
    | Sol_cli_cloud_lifecycle.Permitted -> "permitted"
    | Sol_cli_cloud_lifecycle.Denied -> "denied"
    | Sol_cli_cloud_lifecycle.Indeterminate _ -> "indeterminate"
  in
  let check name expected actual = Alcotest.(check string) name expected (label actual) in
  (* The forms real kubectl emits. *)
  check "yes" "permitted" (classify ~exit_code:0 "yes\n");
  check "no" "denied" (classify ~exit_code:1 "no\n");
  (* Newer kubectl appends a reason after a denial. Matching the whole line would make
     this indeterminate, and every real denial would stop the run. *)
  check
    "no with a reason"
    "denied"
    (classify ~exit_code:1 "no - no RBAC policy matched\n");
  check
    "yes with a trailing line"
    "permitted"
    (classify ~exit_code:0 "yes\nsome trailing line\n");
  (* A token that disagrees with the exit code is not an answer. *)
  check "yes with exit 1" "indeterminate" (classify ~exit_code:1 "yes\n");
  check "no with exit 0" "indeterminate" (classify ~exit_code:0 "no\n");
  (* A transport or token failure: non-zero, nothing on stdout. *)
  check
    "a transport failure"
    "indeterminate"
    (classify ~exit_code:1 ~stderr:"error: unable to connect to the server" "");
  check
    "an unclassifiable answer"
    "indeterminate"
    (classify ~exit_code:1 "something unexpected\n")
;;

(* DEC-040 / FND-0021: de-escalation is decided from the effective authorization
   surface, and only from the principal whose elevation is being removed. The live
   counterexample: an EKS access-policy disassociation was accepted and the API
   reported no access policies while the authorizer still granted cluster-admin for
   over five minutes. *)
let test_deescalation_requires_the_effective_surface () =
  let verdict
        ?(principal = Sol_cli_cloud_lifecycle.Principal_confirmed "…/sol-provisioner")
        probes
    =
    Sol_cli_cloud_lifecycle.deescalation_verdict ~principal probes
  in
  (* Every capability denied is the only thing that licenses the verdict. *)
  Alcotest.(check string)
    "all denied -> de-escalated"
    "de-escalated"
    (match
       verdict
         [ denied (capability "create" "clusterroles")
         ; denied (capability "create" "clusterrolebindings")
         ]
     with
     | Sol_cli_cloud_lifecycle.Deescalated -> "de-escalated"
     | Sol_cli_cloud_lifecycle.Still_elevated _ -> "still elevated"
     | Sol_cli_cloud_lifecycle.Undetermined _ -> "undetermined");
  (* One capability still permitted means the elevated authority is still usable,
     however the revocation was reported. *)
  (match
     verdict
       [ denied (capability "create" "clusterroles")
       ; permitted (capability "escalate" "clusterroles")
       ]
   with
   | Sol_cli_cloud_lifecycle.Still_elevated still ->
     Alcotest.(check (list string))
       "the permitted capability is named"
       [ "escalate clusterroles" ]
       still
   | Sol_cli_cloud_lifecycle.Deescalated ->
     Alcotest.fail "a permitted capability was read as de-escalated"
   | Sol_cli_cloud_lifecycle.Undetermined _ ->
     Alcotest.fail "a permitted capability was read as undetermined");
  (* A definitely-permitted capability outranks another capability's indeterminate probe:
     elevation is hard evidence, and the operator needs it named rather than hidden
     behind "could not tell". *)
  (match
     verdict
       [ permitted (capability "escalate" "clusterroles")
       ; indeterminate (capability "create" "clusterroles") "connection refused"
       ]
   with
   | Sol_cli_cloud_lifecycle.Still_elevated still ->
     Alcotest.(check (list string))
       "the permitted capability is named despite the indeterminate one"
       [ "escalate clusterroles" ]
       still
   | Sol_cli_cloud_lifecycle.Undetermined _ ->
     Alcotest.fail "an indeterminate probe masked a capability that was permitted"
   | Sol_cli_cloud_lifecycle.Deescalated ->
     Alcotest.fail "a permitted capability was read as de-escalated");
  (* No answer is not de-escalation: an unanswered probe must never license Ready. *)
  (match verdict [] with
   | Sol_cli_cloud_lifecycle.Undetermined _ -> ()
   | Sol_cli_cloud_lifecycle.Deescalated ->
     Alcotest.fail "no evidence was read as de-escalated"
   | Sol_cli_cloud_lifecycle.Still_elevated _ ->
     Alcotest.fail "no evidence was read as elevated");
  (* An *indeterminate* answer is not a denial. `kubectl auth can-i` exits non-zero
     when it cannot reach the API or mint a token, and folding that into `no` is how a
     probe that obtained no evidence became evidence of removal (FND-0021). *)
  (match
     verdict [ indeterminate (capability "create" "clusterroles") "connection refused" ]
   with
   | Sol_cli_cloud_lifecycle.Undetermined why ->
     Alcotest.(check bool)
       "the indeterminate capability is named"
       true
       (Sol_cli_port_forward.string_contains ~needle:"connection refused" why)
   | Sol_cli_cloud_lifecycle.Deescalated ->
     Alcotest.fail "an indeterminate probe was read as de-escalated"
   | Sol_cli_cloud_lifecycle.Still_elevated _ ->
     Alcotest.fail "an indeterminate probe was read as elevated");
  (* The principal matters. If the probe answered as somebody else -- a SteadyState
     identity rather than the one whose bootstrap elevation was removed -- its refusals
     prove nothing about that principal, so the verdict may not be de-escalated. This
     is the FND-0021 trap: a check that cannot detect the privilege it testifies about
     must not testify. *)
  (match
     verdict
       ~principal:(Sol_cli_cloud_lifecycle.Principal_unexpected "…/sol-cluster-access")
       [ denied (capability "create" "clusterroles") ]
   with
   | Sol_cli_cloud_lifecycle.Undetermined why ->
     Alcotest.(check bool)
       "the unexpected principal is named"
       true
       (Sol_cli_port_forward.string_contains ~needle:"sol-cluster-access" why)
   | Sol_cli_cloud_lifecycle.Deescalated ->
     Alcotest.fail "another principal's refusal was read as de-escalation"
   | Sol_cli_cloud_lifecycle.Still_elevated _ ->
     Alcotest.fail "another principal's answers were treated as answers");
  (* The cluster refusing an identified principal is the expected post-de-escalation
     state: the capability requires authentication, so its absence is its revocation. *)
  (match
     verdict
       ~principal:
         (Sol_cli_cloud_lifecycle.Principal_refused_by_cluster
            "…/sol-provisioner: Unauthorized")
       []
   with
   | Sol_cli_cloud_lifecycle.Deescalated -> ()
   | Sol_cli_cloud_lifecycle.Still_elevated _ ->
     Alcotest.fail "a refused principal was read as still elevated"
   | Sol_cli_cloud_lifecycle.Undetermined _ ->
     Alcotest.fail "a refused principal was read as undetermined");
  (* ...but failing to *obtain* evidence is not de-escalation. An expired credential, an
     unreachable API or a token-generation failure leaves us knowing nothing, and the
     absence of evidence must not become evidence of de-escalation. *)
  match
    verdict
      ~principal:
        (Sol_cli_cloud_lifecycle.Principal_probe_failed
           "could not establish ephemeral provisioner cluster access")
      []
  with
  | Sol_cli_cloud_lifecycle.Undetermined _ -> ()
  | Sol_cli_cloud_lifecycle.Deescalated ->
    Alcotest.fail "a measurement failure was read as de-escalation"
  | Sol_cli_cloud_lifecycle.Still_elevated _ ->
    Alcotest.fail "a measurement failure was read as still elevated"
;;

(* DEC-040's positive control: only a *transition* of the same principal and the same
   capabilities licenses Ready. Every one of these cases produces a "denied" afterwards,
   and only one of them is evidence. *)
let test_deescalation_requires_a_transition () =
  let caps =
    [ capability "create" "clusterroles"
    ; capability "create" "clusterrolebindings"
    ; capability "escalate" "clusterroles"
    ]
  in
  let granted = List.map permitted caps in
  let refused = List.map denied caps in
  let confirmed = Sol_cli_cloud_lifecycle.Principal_confirmed "…/sol-provisioner" in
  let not_a_transition before =
    match
      Sol_cli_cloud_lifecycle.deescalation_transition
        ~before
        ~after_principal:confirmed
        ~after:refused
    with
    | Sol_cli_cloud_lifecycle.Undetermined _ -> ()
    | Sol_cli_cloud_lifecycle.Deescalated ->
      Alcotest.fail
        "a capability never observed granted was read as a verified transition"
    | Sol_cli_cloud_lifecycle.Still_elevated _ ->
      Alcotest.fail "a capability never observed granted was read as still elevated"
  in
  (* 1. The capability was never observed granted in the window: nothing was removed. *)
  not_a_transition [];
  not_a_transition refused;
  (* 1b. A capability that was *indeterminate* in the window was never shown to be
     granted, so its later denial is not evidence that it was removed. *)
  not_a_transition
    [ indeterminate (capability "create" "clusterroles") "the API was unreachable" ];
  (* 2. A different principal answered after de-escalation: the transition is not
     established, however clean the denial looks. *)
  (match
     Sol_cli_cloud_lifecycle.deescalation_transition
       ~before:granted
       ~after_principal:
         (Sol_cli_cloud_lifecycle.Principal_unexpected "…/sol-cluster-access")
       ~after:refused
   with
   | Sol_cli_cloud_lifecycle.Undetermined _ -> ()
   | Sol_cli_cloud_lifecycle.Deescalated ->
     Alcotest.fail "a different principal's denial was read as a verified transition"
   | Sol_cli_cloud_lifecycle.Still_elevated _ -> Alcotest.fail "unexpected verdict");
  (* 3. A measurement failure after de-escalation leaves us knowing nothing. *)
  (match
     Sol_cli_cloud_lifecycle.deescalation_transition
       ~before:granted
       ~after_principal:
         (Sol_cli_cloud_lifecycle.Principal_probe_failed "expired credentials")
       ~after:refused
   with
   | Sol_cli_cloud_lifecycle.Undetermined _ -> ()
   | Sol_cli_cloud_lifecycle.Deescalated ->
     Alcotest.fail "a measurement failure was read as a verified transition"
   | Sol_cli_cloud_lifecycle.Still_elevated _ -> Alcotest.fail "unexpected verdict");
  (* 4. Granted before, denied after, same principal and capabilities: the only shape
     that licenses Ready. *)
  (match
     Sol_cli_cloud_lifecycle.deescalation_transition
       ~before:granted
       ~after_principal:confirmed
       ~after:refused
   with
   | Sol_cli_cloud_lifecycle.Deescalated -> ()
   | Sol_cli_cloud_lifecycle.Still_elevated _ ->
     Alcotest.fail "a demonstrated transition was read as still elevated"
   | Sol_cli_cloud_lifecycle.Undetermined why ->
     Alcotest.fail ("a demonstrated transition was read as undetermined: " ^ why));
  (* 5. A capability that comes back *indeterminate* after de-escalation is not a
     denial: the surface was not established. Without the tri-state this read as
     Deescalated -- the fail-open this case exists to pin. *)
  (match
     Sol_cli_cloud_lifecycle.deescalation_transition
       ~before:granted
       ~after_principal:confirmed
       ~after:
         [ indeterminate (capability "create" "clusterroles") "connection refused"
         ; denied (capability "create" "clusterrolebindings")
         ; denied (capability "escalate" "clusterroles")
         ]
   with
   | Sol_cli_cloud_lifecycle.Undetermined _ -> ()
   | Sol_cli_cloud_lifecycle.Deescalated ->
     Alcotest.fail "an indeterminate post-de-escalation probe was read as de-escalated"
   | Sol_cli_cloud_lifecycle.Still_elevated _ -> Alcotest.fail "unexpected verdict");
  (* 6. A probe that stops covering a capability observed granted in the window cannot
     license a verdict about it. *)
  (match
     Sol_cli_cloud_lifecycle.deescalation_transition
       ~before:granted
       ~after_principal:confirmed
       ~after:
         [ denied (capability "create" "clusterroles")
         ; denied (capability "create" "clusterrolebindings")
         ]
   with
   | Sol_cli_cloud_lifecycle.Undetermined _ -> ()
   | Sol_cli_cloud_lifecycle.Deescalated ->
     Alcotest.fail "a capability the after-probe never covered was read as removed"
   | Sol_cli_cloud_lifecycle.Still_elevated _ -> Alcotest.fail "unexpected verdict");
  (* 7. A definitely-permitted capability after de-escalation outranks another
     capability's indeterminate probe: it is hard evidence of elevation, and the operator
     needs it named. *)
  (match
     Sol_cli_cloud_lifecycle.deescalation_transition
       ~before:granted
       ~after_principal:confirmed
       ~after:
         [ permitted (capability "escalate" "clusterroles")
         ; indeterminate (capability "create" "clusterroles") "connection refused"
         ]
   with
   | Sol_cli_cloud_lifecycle.Still_elevated still ->
     Alcotest.(check (list string))
       "the permitted capability is named despite the indeterminate one"
       [ "escalate clusterroles" ]
       still
   | Sol_cli_cloud_lifecycle.Undetermined _ ->
     Alcotest.fail "an indeterminate probe masked a capability that was permitted"
   | Sol_cli_cloud_lifecycle.Deescalated ->
     Alcotest.fail "a permitted capability was read as de-escalated");
  (* ... and if the capability is still permitted, it is still elevated -- the positive
     control makes that observable rather than merely assumed. *)
  match
    Sol_cli_cloud_lifecycle.deescalation_transition
      ~before:granted
      ~after_principal:confirmed
      ~after:granted
  with
  | Sol_cli_cloud_lifecycle.Still_elevated still ->
    Alcotest.(check int) "all three capabilities named" 3 (List.length still)
  | Sol_cli_cloud_lifecycle.Deescalated ->
    Alcotest.fail "a still-permitted capability was read as de-escalated"
  | Sol_cli_cloud_lifecycle.Undetermined _ -> Alcotest.fail "unexpected verdict"
;;

(* DEC-040: the principal is identified from a real SelfSubjectReview shape.

   On EKS the AWS authenticator reports identity under status.userInfo.extra, where every
   value is an array of strings -- including arn and canonicalArn. An earlier version
   looked only for a plain string arn in userInfo, which is not what EKS produces, and
   would have failed closed on every real install. The flat form is still covered because
   other authenticators and stubs emit it.

   The live response is captured into this fixture during the next bootstrap epoch (see
   the run-record template); these lock in the documented shape meanwhile. *)
let test_whoami_identity_shapes () =
  let sts = "arn:aws:sts::111122223333:assumed-role/sol-provisioner/EKSGetTokenAuth" in
  let canonical = "arn:aws:iam::111122223333:role/sol-provisioner" in
  let eks_body session =
    Printf.sprintf
      {|{"apiVersion":"authentication.k8s.io/v1","kind":"SelfSubjectReview","metadata":{"creationTimestamp":null},"status":{"userInfo":{"username":"%s","uid":"aws-iam-authenticator:111122223333:AROA","groups":["system:authenticated","sol:platform-provisioners"],"extra":{"arn":["arn:aws:sts::111122223333:assumed-role/sol-provisioner/%s"],"canonicalArn":["%s"],"sessionName":["%s"],"principalId":["AROA:logan"]}}}}|}
      sts
      session
      canonical
      session
  in
  let role_of body =
    match Sol_cli_aws_cluster.whoami_identity_of_json body with
    | Ok i -> Sol_cli_aws_cluster.principal_role_name i
    | Error e -> Alcotest.fail e
  in
  (* the EKS shape: arrays under extra, canonicalArn present *)
  Alcotest.(check (option string))
    "eks shape yields the role"
    (Some "sol-provisioner")
    (role_of (eks_body "EKSGetTokenAuth"));
  (* the session name changes between probes of the same principal -- that must not read
     as a principal mismatch, or the transition would be Undetermined for no reason *)
  Alcotest.(check (option string))
    "a new session is still the same principal"
    (role_of (eks_body "EKSGetTokenAuth"))
    (role_of (eks_body "some-other-session"));
  (* the flat string form, which other authenticators and the stubs emit *)
  let flat = Printf.sprintf {|{"status":{"userInfo":{"arn":"%s"}}}|} canonical in
  Alcotest.(check (option string))
    "flat string form"
    (Some "sol-provisioner")
    (role_of flat);
  (* pretty-printed, in case the emitter ever formats it *)
  let pretty =
    Printf.sprintf
      {|{
  "status": {
    "userInfo": {
      "extra": {
        "canonicalArn": [
          "%s"
        ]
      }
    }
  }
}|}
      canonical
  in
  Alcotest.(check (option string))
    "pretty-printed"
    (Some "sol-provisioner")
    (role_of pretty);
  (* username as the last resort, and no principal at all is Error -- never a default *)
  (match
     Sol_cli_aws_cluster.whoami_identity_of_json
       {|{"status":{"userInfo":{"username":"system:node:ip-10-0-1-1"}}}|}
   with
   | Ok i ->
     Alcotest.(check (option string))
       "username is the last resort"
       (Some "system:node:ip-10-0-1-1")
       (Sol_cli_aws_cluster.principal_role_name i)
   | Error e -> Alcotest.fail e);
  (match Sol_cli_aws_cluster.whoami_identity_of_json {|{"status":{"userInfo":{}}}|} with
   | Error _ -> ()
   | Ok i ->
     Alcotest.fail
       ("a response naming no principal produced "
        ^ Option.value (Sol_cli_aws_cluster.principal_role_name i) ~default:"?"));
  (match Sol_cli_aws_cluster.whoami_identity_of_json "error: You must be logged in" with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "a non-JSON response was accepted");
  (* the role name extraction itself, both ARN forms *)
  Alcotest.(check string)
    "assumed-role ARN"
    "sol-provisioner"
    (Sol_cli_aws_cluster.role_name_of_arn sts);
  Alcotest.(check string)
    "role ARN"
    "sol-provisioner"
    (Sol_cli_aws_cluster.role_name_of_arn canonical)
;;

(* DEC-040: the principal comparison must fail *closed*, and a parse failure must land in
   Undetermined rather than in a verdict.

   The previous comparison extracted a role name, which fails open: the same role name in
   another account, or behind a different role path, would look like the same principal --
   and a different principal being denied afterwards would read as Deescalated. *)
let test_principal_comparison_fails_closed () =
  let expected = "arn:aws:iam::111122223333:role/sol-provisioner" in
  let identity ?canonical ?arn ?username () =
    Sol_cli_aws_cluster.{ canonical_arn = canonical; arn; username; source = "test" }
  in
  Alcotest.(check (option bool))
    "exact match"
    (Some true)
    (Sol_cli_aws_cluster.principal_matches ~expected (identity ~canonical:expected ()));
  Alcotest.(check (option bool))
    "same role name in another account"
    (Some false)
    (Sol_cli_aws_cluster.principal_matches
       ~expected
       (identity
          ~canonical:("arn:aws:iam::" ^ String.make 12 '9' ^ ":role/sol-provisioner")
          ()));
  Alcotest.(check (option bool))
    "same role behind a different path"
    (Some false)
    (Sol_cli_aws_cluster.principal_matches
       ~expected
       (identity ~canonical:"arn:aws:iam::111122223333:role/team/sol-provisioner" ()));
  Alcotest.(check (option bool))
    "a session-carrying arn is not a role arn"
    (Some false)
    (Sol_cli_aws_cluster.principal_matches
       ~expected
       (identity
          ~arn:"arn:aws:sts::111122223333:assumed-role/sol-provisioner/EKSGetTokenAuth"
          ()));
  Alcotest.(check (option bool))
    "no arn at all is None, not a default"
    None
    (Sol_cli_aws_cluster.principal_matches ~expected (identity ~username:"somebody" ()))
;;

(* A parse failure must be Undetermined on *both* sides of the transition. If it fell
   through to a verdict it would be a wrong verdict, not a safe failure -- and this was on
   the not-yet-applied list, so nothing proved it. *)
let test_parse_failure_is_undetermined () =
  let granted = [ permitted (capability "create" "clusterroles") ] in
  let refused = [ denied (capability "create" "clusterroles") ] in
  let confirmed = Sol_cli_cloud_lifecycle.Principal_confirmed "arn:aws:iam::1:role/p" in
  let parse_failure =
    match Sol_cli_aws_cluster.whoami_identity_of_json "error: You must be logged in" with
    | Error why -> Sol_cli_cloud_lifecycle.Principal_probe_failed why
    | Ok _ -> Alcotest.fail "a non-JSON response was accepted by the parser"
  in
  let check_undetermined label verdict =
    match verdict with
    | Sol_cli_cloud_lifecycle.Undetermined _ -> ()
    | Sol_cli_cloud_lifecycle.Deescalated ->
      Alcotest.fail (label ^ ": a parse failure was read as de-escalated")
    | Sol_cli_cloud_lifecycle.Still_elevated _ ->
      Alcotest.fail (label ^ ": a parse failure was read as still elevated")
  in
  (* after: the post-de-escalation probe could not identify the principal *)
  check_undetermined
    "after"
    (Sol_cli_cloud_lifecycle.deescalation_transition
       ~before:granted
       ~after_principal:parse_failure
       ~after:refused);
  (* before: the window control could not identify the principal, so nothing was shown to
     have been removed *)
  check_undetermined
    "before"
    (Sol_cli_cloud_lifecycle.deescalation_transition
       ~before:[]
       ~after_principal:confirmed
       ~after:refused)
;;

(* DEC-040: what the parser does with an *ambiguous* array, asserted rather than argued.

   A response whose canonicalArn has more than one entry names more than one principal. The
   argument for treating that as safe was that the exact comparison cannot confirm a
   principal it never saw -- which holds for a false Deescalated, but it is an argument, not
   a check. This asserts the mapping. If it fails, the parser returns a principal and
   proceeds, and "believed closed" becomes a known gap; if it passes, it is verified. *)
let test_ambiguous_array_does_not_proceed () =
  let two_entries =
    {|{"status":{"userInfo":{"extra":{"canonicalArn":["arn:aws:iam::111122223333:role/sol-provisioner","arn:aws:iam::111122223333:role/sol-cluster-access"]}}}}|}
  in
  match Sol_cli_aws_cluster.whoami_identity_of_json two_entries with
  | Error _ -> () (* refused: the ambiguity cannot produce a verdict *)
  | Ok identity ->
    Alcotest.fail
      (Printf.sprintf
         "a two-entry canonicalArn was accepted and produced %s; taking one element is a \
          default in disguise, and the array is ambiguous about which principal this is"
         (Option.value (Sol_cli_aws_cluster.principal_role_name identity) ~default:"?"))
;;

(* DEC-040: the identity must report *which field* it came from. The gate requires
   canonicalArn, because that is the field the de-escalation comparison depends on -- a pass
   via the arn or username fallbacks would validate a path the comparison does not use. *)
let test_identity_reports_its_source () =
  let source_of body =
    match Sol_cli_aws_cluster.whoami_identity_of_json body with
    | Ok i -> i.Sol_cli_aws_cluster.source
    | Error e -> Alcotest.fail e
  in
  Alcotest.(check string)
    "canonicalArn from extra"
    "extra.canonicalArn"
    (source_of
       {|{"status":{"userInfo":{"extra":{"canonicalArn":["arn:aws:iam::111122223333:role/p"]}}}}|});
  Alcotest.(check string)
    "arn from extra when there is no canonicalArn"
    "extra.arn"
    (source_of
       {|{"status":{"userInfo":{"extra":{"arn":["arn:aws:iam::111122223333:role/p"]}}}}|});
  Alcotest.(check string)
    "the username fallback is named as such"
    "username"
    (source_of {|{"status":{"userInfo":{"username":"system:node:ip-10-0-1-1"}}}|})
;;

(* DEC-040: a refusal is evidence of removal only if the credential is still good.
   "You must be logged in" is also what a working credential gets when the role's trust
   policy is broken, the clock is skewed, or the wrong role was assumed -- and
   Principal_refused_by_cluster maps straight to Deescalated. Without the identity check that
   is a fail-open into the one verdict that has to mean something. *)
let test_refusal_needs_a_good_identity () =
  let granted = [ permitted (capability "create" "clusterroles") ] in
  let refused = [ denied (capability "create" "clusterroles") ] in
  let verdict_of assumption =
    Sol_cli_cloud_lifecycle.deescalation_transition
      ~before:granted
      ~after_principal:
        (Sol_cli_aws_cluster.refusal_is_deescalation assumption "Unauthorized")
      ~after:refused
  in
  (* the credential is good: the refusal is the removal *)
  (match verdict_of Sol_cli_aws_cluster.Credential_assumable with
   | Sol_cli_cloud_lifecycle.Deescalated -> ()
   | _ -> Alcotest.fail "a refusal with a working identity was not read as de-escalated");
  (* the credential is broken: a revocation cannot be told from a bad trust policy *)
  (match verdict_of Sol_cli_aws_cluster.Credential_refused with
   | Sol_cli_cloud_lifecycle.Undetermined _ -> ()
   | Sol_cli_cloud_lifecycle.Deescalated ->
     Alcotest.fail "a refusal with an unassumable role was read as de-escalated"
   | Sol_cli_cloud_lifecycle.Still_elevated _ ->
     Alcotest.fail "a refusal with an unassumable role was read as still elevated");
  (* the identity check could not be performed at all *)
  match verdict_of Sol_cli_aws_cluster.Credential_unchecked with
  | Sol_cli_cloud_lifecycle.Undetermined _ -> ()
  | Sol_cli_cloud_lifecycle.Deescalated ->
    Alcotest.fail "a refusal with no identity check was read as de-escalated"
  | Sol_cli_cloud_lifecycle.Still_elevated _ ->
    Alcotest.fail "a refusal with no identity check was read as still elevated"
;;

let test_effective_authorization () =
  let open L in
  let expected = provisioner_authorization_checks in
  let can_i args =
    match
      List.assoc_opt args (List.map (fun (result, argv) -> argv, result) expected)
    with
    | Some Required -> true
    | Some Forbidden -> false
    | None -> Alcotest.fail "authorization check was not declared"
  in
  Alcotest.(check bool)
    "declared boundary"
    true
    (provisioner_authorization_established ~can_i);
  List.iter
    (fun (_, failed) ->
       Alcotest.(check bool)
         (String.concat " " failed)
         false
         (provisioner_authorization_established ~can_i:(fun args ->
            if args = failed then not (can_i args) else can_i args)))
    expected
;;

let test_terraform_scope () =
  ignore (Sol_cli_terraform.targets "helm_release.cert_manager" []);
  Alcotest.check_raises
    "empty target rejected"
    (Invalid_argument "Terraform target must not be empty")
    (fun () -> ignore (Sol_cli_terraform.targets "" []));
  ignore Sol_cli_terraform.whole_root
;;

let () =
  Alcotest.run
    "cloud lifecycle"
    [ ( "contracts"
      , [ Alcotest.test_case "strict AWS outputs" `Quick test_outputs
        ; Alcotest.test_case
            "absent optional AWS outputs"
            `Quick
            test_outputs_absent_optional
        ; Alcotest.test_case "strict GCP outputs" `Quick test_gcp_outputs
        ; Alcotest.test_case
            "provider-shaped platform variables"
            `Quick
            test_platform_terraform_vars
        ; Alcotest.test_case "cluster identity check" `Quick test_cluster_identity_check
        ; Alcotest.test_case
            "a preparation failure's policy decides"
            `Quick
            test_preparation_failure_policies
        ; Alcotest.test_case
            "preparation targets only what state represents"
            `Quick
            test_preparations_eligible
        ; Alcotest.test_case
            "destruction is not refused by an install-time requirement"
            `Quick
            test_platform_vars_destruction_context
        ; Alcotest.test_case "provisioner kubeconfig env" `Quick test_provisioner_kube_env
        ; Alcotest.test_case "lifecycle phases and policy" `Quick test_lifecycle_phases
        ; Alcotest.test_case "separate backends" `Quick test_backends
        ; Alcotest.test_case "provider-shaped cloud target" `Quick test_cloud_target
        ; Alcotest.test_case
            "provider-specific platform root"
            `Quick
            test_platform_root_selection
        ; Alcotest.test_case "deferred plan" `Quick test_deferred
        ; Alcotest.test_case
            "readiness predicates"
            `Quick
            test_readiness_fails_each_predicate
        ; Alcotest.test_case
            "provider-specific storage contract"
            `Quick
            test_storage_contract_is_provider_specific
        ; Alcotest.test_case
            "provider-specific readiness invocations"
            `Quick
            test_readiness_invocations_are_provider_specific
        ; Alcotest.test_case "convergence predicates" `Quick test_convergence_predicates
        ; Alcotest.test_case "destroy retention" `Quick test_destroy_retention
        ; Alcotest.test_case "effective authorization" `Quick test_effective_authorization
        ; Alcotest.test_case
            "can-i answer classification (DEC-040)"
            `Quick
            test_can_i_classification
        ; Alcotest.test_case
            "verified de-escalation (DEC-040)"
            `Quick
            test_deescalation_requires_the_effective_surface
        ; Alcotest.test_case
            "whoami identity shapes (DEC-040)"
            `Quick
            test_whoami_identity_shapes
        ; Alcotest.test_case
            "principal comparison fails closed (DEC-040)"
            `Quick
            test_principal_comparison_fails_closed
        ; Alcotest.test_case
            "ambiguous array (DEC-040)"
            `Quick
            test_ambiguous_array_does_not_proceed
        ; Alcotest.test_case
            "a refusal needs a good identity (DEC-040)"
            `Quick
            test_refusal_needs_a_good_identity
        ; Alcotest.test_case
            "identity reports its source (DEC-040)"
            `Quick
            test_identity_reports_its_source
        ; Alcotest.test_case
            "parse failure is Undetermined (DEC-040)"
            `Quick
            test_parse_failure_is_undetermined
        ; Alcotest.test_case
            "verified de-escalation is a transition (DEC-040)"
            `Quick
            test_deescalation_requires_a_transition
        ; Alcotest.test_case "terraform scope" `Quick test_terraform_scope
        ] )
    ]
;;
