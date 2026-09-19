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
  let destroy_vars = policy_vars ~phase:Preparing_destroy ~destroy_snapshot_id:"snap-1" in
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
  Alcotest.(check int)
    "Ready adds no policy overrides"
    0
    (List.length (policy_vars ~phase:Ready ~destroy_snapshot_id:"x"));
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
  let get root = Result.get_ok (L.backend_config target ~root) in
  let cloud = get `Cloud
  and platform = get `Platform in
  Alcotest.(check bool) "distinct" true (cloud <> platform);
  Alcotest.(check bool)
    "cloud key"
    true
    (List.mem "key=sol/prod/aws/us-east-1/cloud.tfstate" cloud);
  Alcotest.(check bool)
    "platform key"
    true
    (List.mem "key=sol/prod/aws/us-east-1/platform.tfstate" platform)
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

let test_readiness_fails_each_predicate () =
  let succeeds = function
    | "get" :: "storageclass/gp3" :: _ -> Some "ebs.csi.aws.com true"
    | "get" :: "service/ingress-nginx-controller" :: _ -> Some "example.elb.amazonaws.com"
    (* The convergence checks read status, so the baseline has to supply it. *)
    | "get" :: "daemonset" :: _ -> Some "4/4 4/4 "
    | "get" :: "statefulset" :: _ -> Some "3/3 1/1 "
    | "get" :: "pvc" :: _ -> Some "Bound Bound "
    | "get" :: "nodes" :: _ -> Some "True True "
    | _ -> Some ""
  in
  let all = L.readiness ~run:succeeds in
  Alcotest.(check string) "baseline" "Ready" (L.readiness_summary all);
  List.iteri
    (fun failed _ ->
       let index = ref (-1) in
       let checks =
         L.readiness ~run:(fun argv ->
           incr index;
           if !index = failed then None else succeeds argv)
       in
       Alcotest.(check bool)
         (Printf.sprintf "predicate %d fails closed" failed)
         true
         (L.readiness_summary checks <> "Ready"))
    all
;;

(* The convergence predicates decide whether `sol cloud apply` may report [Ready],
   so the ways they could pass vacuously are worth pinning: an empty listing, and
   a listing that says nothing useful. DaemonSets additionally require a desired
   count — zero means the node set matched nothing — while StatefulSets do not,
   because their replicas are declared by their owner. *)
let test_convergence_predicates () =
  let summary_with kind output =
    L.readiness ~run:(fun argv ->
      match argv with
      | "get" :: listed :: _ when listed = kind -> Some output
      | "get" :: "storageclass/gp3" :: _ -> Some "ebs.csi.aws.com true"
      | "get" :: "service/ingress-nginx-controller" :: _ ->
        Some "example.elb.amazonaws.com"
      | "get" :: "daemonset" :: _ -> Some "4/4 4/4 "
      | "get" :: "statefulset" :: _ -> Some "3/3 1/1 "
      | "get" :: "pvc" :: _ -> Some "Bound Bound "
      | "get" :: "nodes" :: _ -> Some "True True "
      | _ -> Some "")
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
        ; Alcotest.test_case "provisioner kubeconfig env" `Quick test_provisioner_kube_env
        ; Alcotest.test_case "lifecycle phases and policy" `Quick test_lifecycle_phases
        ; Alcotest.test_case "separate backends" `Quick test_backends
        ; Alcotest.test_case "deferred plan" `Quick test_deferred
        ; Alcotest.test_case
            "readiness predicates"
            `Quick
            test_readiness_fails_each_predicate
        ; Alcotest.test_case "convergence predicates" `Quick test_convergence_predicates
        ; Alcotest.test_case "effective authorization" `Quick test_effective_authorization
        ; Alcotest.test_case "terraform scope" `Quick test_terraform_scope
        ] )
    ]
;;
