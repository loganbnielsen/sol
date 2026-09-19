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
  ; state_lock_table = Some "acme-lock"
  ; provisioner_role_arn = Some "arn:aws:iam::1:role/provisioner"
  ; deploy_role_arn = None
  ; operator_role_arn = None
  ; cluster_endpoint_cidr = None
  ; node_failure_headroom_nodes = None
  ; profile = None
  ; provider_fields = []
  }
;;

let output ?(value = `String "x") name =
  name, `Assoc [ "sensitive", `Bool false; "value", value ]
;;

let valid_outputs () =
  `Assoc
    [ output "cluster_name" ~value:(`String "acme-prod")
    ; output "kubeconfig_command"
    ; output "provisioner_role_arn" ~value:(`String "arn:aws:iam::1:role/provisioner")
    ; output "cert_manager_irsa_arn" ~value:(`String "arn:aws:iam::1:role/cert-manager")
    ; output "loki_s3_bucket" ~value:(`String "loki")
    ; output "loki_irsa_arn" ~value:(`String "loki-role")
    ; output "thanos_s3_bucket" ~value:(`String "thanos")
    ; output "thanos_irsa_arn" ~value:(`String "thanos-role")
    ; output "grafana_irsa_arn" ~value:`Null
    ; output "managed_resource_dashboards" ~value:(`Assoc [])
    ]
;;

let parse json = L.aws_outputs_of_json (Yojson.Safe.to_string json)

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
    ; output "loki_gcs_bucket" ~value:`Null
    ; output "thanos_gcs_bucket" ~value:`Null
    ; output "loki_workload_identity_sa_email" ~value:`Null
    ; output "thanos_workload_identity_sa_email" ~value:`Null
    ]
;;

let parse_gcp json = L.gcp_outputs_of_json (Yojson.Safe.to_string json)

let without_output name json =
  match json with
  | `Assoc fields -> `Assoc (List.remove_assoc name fields)
  | _ -> assert false
;;

let test_gcp_outputs () =
  (match parse_gcp (valid_gcp_outputs ()) with
   | Ok outputs ->
     Alcotest.(check string) "cluster" "sol-qual" outputs.L.cluster_name;
     Alcotest.(check string) "project" "sol-qualification" outputs.L.project_id;
     Alcotest.(check string) "region" "us-central1" outputs.L.region;
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
    [ "cluster_name"; "project_id"; "region"; "artifact_registry" ];
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
  ; state_lock_table = None
  ; provisioner_role_arn = None
  ; kube_context =
      Some "gke_sol-qualification_us-central1_sol"
      (* The base target names a ClusterIssuer; this one deliberately does not, so
       the plain case is the case under test. GCP cannot wire an issuer yet, and
       asking for one is asserted separately. *)
  ; cluster_issuer = None
  }
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
    L.Aws_outputs
      (Result.get_ok (L.aws_outputs_of_json (Yojson.Safe.to_string (valid_outputs ()))))
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
    L.Gcp_outputs
      (Result.get_ok
         (L.gcp_outputs_of_json (Yojson.Safe.to_string (valid_gcp_outputs ()))))
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

(* HARDEN-002 run 4, finding 12: the base providers (hashicorp/kubernetes,
   hashicorp/helm) resolve the kubeconfig from KUBE_CONFIG_PATH/KUBE_CONFIG_PATHS,
   not KUBECONFIG. Every name must point at the ephemeral provisioner kubeconfig,
   or the platform phase silently uses the ambient ~/.kube/config. *)
let test_provisioner_kube_env () =
  let path = "/tmp/sol-platform-provisioner-test.kubeconfig" in
  let env = L.provisioner_kube_env path in
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
  let aws_without_lock = { target with state_lock_table = None } in
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
    ; state_lock_table = None
    ; provisioner_role_arn = None
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
     L.backend_config { gcp with state_lock_table = Some "unnecessary" } ~root:`Cloud
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
    ; state_lock_table = None
    ; provisioner_role_arn = None
    ; kube_context = Some "gke_sol-qualification_us-central1_sol"
    }
  in
  let aws = Result.get_ok (L.cloud_target target) in
  Alcotest.(check bool)
    "AWS carries the provisioner role it must assume"
    true
    (aws.provisioner_role_arn = Some "arn:aws:iam::1:role/provisioner");
  let gcp = Result.get_ok (L.cloud_target gcp) in
  Alcotest.(check bool)
    "GCP carries no role ARN and is not refused for it"
    true
    (gcp.provisioner_role_arn = None);
  Alcotest.(check string) "region travels from the target" "us-central1" gcp.target.region;
  Alcotest.(check (list string))
    "the target's own backends are the ones selected"
    [ "bucket=acme-state"; "prefix=sol/prod/gcp/us-central1/platform.tfstate" ]
    gcp.platform_backend;
  (match L.cloud_target { target with provisioner_role_arn = None } with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "an AWS target without a provisioner role must be refused");
  match L.cloud_target { target with base_domain = None } with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "a target without a base domain must be refused"
;;

(* The platform root differs per provider because a Terraform root's backend type
   is part of its own configuration, and the address prefix follows the structure
   that reaches the shared definition. The two have to agree: a provider whose root
   is `base` cannot be addressed through `module.platform`. *)
let test_platform_root_selection () =
  Alcotest.(check string)
    "AWS keeps the shared definition as its own root"
    "cli/platform/infra/base"
    (L.platform_root Sol_cli_provider.Aws);
  Alcotest.(check string)
    "GCP has a root that declares the GCS backend"
    "cli/platform/infra/base-gcp"
    (L.platform_root Sol_cli_provider.Gcp);
  Alcotest.(check string)
    "an AWS address is bare"
    "kubernetes_namespace.cert_manager"
    (L.platform_address Sol_cli_provider.Aws "kubernetes_namespace.cert_manager");
  Alcotest.(check string)
    "a GCP address goes through the module that reaches the definition"
    "module.platform.kubernetes_namespace.cert_manager"
    (L.platform_address Sol_cli_provider.Gcp "kubernetes_namespace.cert_manager");
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
  let has needle haystack =
    let n = String.length needle
    and h = String.length haystack in
    let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
    go 0
  in
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
     = Some "false");
  Alcotest.(check bool)
    "the report names the snapshot and how to remove it"
    true
    (let report =
       L.retention_report ~retention:L.Retain_final_snapshot ~destroy_snapshot_id:"snap-1"
     in
     has "snap-1" report && has "delete-db-snapshot" report);
  Alcotest.(check bool)
    "the report says a disposable destroy keeps nothing"
    true
    (let report =
       L.retention_report ~retention:L.Retain_nothing ~destroy_snapshot_id:"snap-1"
     in
     has "no residual billable artifacts" report)
;;

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
        ; Alcotest.test_case "terraform scope" `Quick test_terraform_scope
        ] )
    ]
;;
