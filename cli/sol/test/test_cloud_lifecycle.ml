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
    | _ -> Some ""
  in
  let all =
    L.readiness
      ~cluster_issuer:"letsencrypt-prod"
      ~observability_backend:"self_hosted_durable"
      ~run:succeeds
  in
  Alcotest.(check string) "baseline" "Ready" (L.readiness_summary all);
  List.iteri
    (fun failed _ ->
       let index = ref (-1) in
       let checks =
         L.readiness
           ~cluster_issuer:"letsencrypt-prod"
           ~observability_backend:"self_hosted_durable"
           ~run:(fun argv ->
             incr index;
             if !index = failed then None else succeeds argv)
       in
       Alcotest.(check bool)
         (Printf.sprintf "predicate %d fails closed" failed)
         true
         (L.readiness_summary checks <> "Ready"))
    all
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
        ; Alcotest.test_case "separate backends" `Quick test_backends
        ; Alcotest.test_case "deferred plan" `Quick test_deferred
        ; Alcotest.test_case
            "readiness predicates"
            `Quick
            test_readiness_fails_each_predicate
        ; Alcotest.test_case "effective authorization" `Quick test_effective_authorization
        ; Alcotest.test_case "terraform scope" `Quick test_terraform_scope
        ] )
    ]
;;
