let k8s_name value =
  match Sol_cli_deployment_plan.k8s_name_result value with
  | Ok name -> name
  | Error err -> Alcotest.fail (Sol_cli_deployment_plan.plan_error_to_string err)
;;

let namespace ~workspace ~domain =
  Sol_cli_deployment_plan.namespace_of_exn ~workspace ~domain
;;

let cpu s =
  match Sol_cli_toml.cpu_quantity_of_string s with
  | Ok quantity -> quantity
  | Error message -> Alcotest.fail message
;;

let memory s =
  match Sol_cli_toml.memory_quantity_of_string s with
  | Ok quantity -> quantity
  | Error message -> Alcotest.fail message
;;

let base_spec : Sol_cli_deployment_plan.service_spec =
  { domain = "payments"
  ; source_name = "charge_svc"
  ; k8s_name = k8s_name "charge-svc"
  ; namespace = namespace ~workspace:"myapp" ~domain:"payments"
  ; primitive = Sol_cli_deployment_plan.Svc
  ; source_dir = "app/payments/charge_svc"
  ; image = ""
  ; config = []
  ; secrets = []
  ; volumes = []
  ; schedule = None
  ; replicas = 1
  ; cpu = cpu "100m"
  ; memory = memory "128Mi"
  ; rollout_strategy = None
  ; ingress_host = None
  ; ingress_path = None
  ; cluster_issuer = "letsencrypt-prod"
  ; extra_labels = []
  ; progressive_delivery = None
  }
;;

(* ── rollback_target_of_service ─────────────────────────────────────────── *)

let test_svc_gives_standard_deployment () =
  let spec = { base_spec with primitive = Sol_cli_deployment_plan.Svc } in
  match Sol_cli_rollback.rollback_target_of_service spec with
  | Sol_cli_rollback.Standard_deployment { namespace; name } ->
    Alcotest.(check string) "namespace" "myapp-payments" namespace;
    Alcotest.(check string) "name" "charge-svc" name
  | other ->
    let label =
      match other with
      | Sol_cli_rollback.Argo_rollout _ -> "Argo_rollout"
      | Sol_cli_rollback.No_op _ -> "No_op"
      | Sol_cli_rollback.Standard_deployment _ -> "Standard_deployment"
    in
    Alcotest.failf "expected Standard_deployment, got %s" label
;;

let test_worker_gives_standard_deployment () =
  let spec =
    { base_spec with
      primitive = Sol_cli_deployment_plan.Worker
    ; source_name = "notify_worker"
    ; k8s_name = k8s_name "notify-worker"
    ; namespace = namespace ~workspace:"myapp" ~domain:"comms"
    ; domain = "comms"
    }
  in
  match Sol_cli_rollback.rollback_target_of_service spec with
  | Sol_cli_rollback.Standard_deployment { namespace; name } ->
    Alcotest.(check string) "namespace" "myapp-comms" namespace;
    Alcotest.(check string) "name" "notify-worker" name
  | _ -> Alcotest.fail "expected Standard_deployment for worker"
;;

let test_fn_gives_no_op () =
  let spec =
    { base_spec with
      primitive = Sol_cli_deployment_plan.Fn
    ; source_name = "cleanup_fn"
    ; k8s_name = k8s_name "cleanup-fn"
    ; schedule = Some "0 * * * *"
    }
  in
  match Sol_cli_rollback.rollback_target_of_service spec with
  | Sol_cli_rollback.No_op reason -> assert (String.length reason > 0)
  | _ -> Alcotest.fail "expected No_op for Fn primitive"
;;

let test_progressive_delivery_gives_argo_rollout () =
  let spec =
    { base_spec with progressive_delivery = Some (Sol_cli_toml.Canary { steps = [] }) }
  in
  match Sol_cli_rollback.rollback_target_of_service spec with
  | Sol_cli_rollback.Argo_rollout { namespace; name } ->
    Alcotest.(check string) "namespace" "myapp-payments" namespace;
    Alcotest.(check string) "name" "charge-svc" name
  | _ -> Alcotest.fail "expected Argo_rollout for progressive_delivery=canary"
;;

let test_blue_green_gives_argo_rollout () =
  let spec = { base_spec with progressive_delivery = Some Sol_cli_toml.Blue_green } in
  match Sol_cli_rollback.rollback_target_of_service spec with
  | Sol_cli_rollback.Argo_rollout _ -> ()
  | _ -> Alcotest.fail "expected Argo_rollout for progressive_delivery=blue_green"
;;

let test_worker_with_argo_gives_argo_rollout () =
  let spec =
    { base_spec with
      primitive = Sol_cli_deployment_plan.Worker
    ; progressive_delivery = Some (Sol_cli_toml.Canary { steps = [] })
    }
  in
  match Sol_cli_rollback.rollback_target_of_service spec with
  | Sol_cli_rollback.Argo_rollout _ -> ()
  | _ -> Alcotest.fail "expected Argo_rollout for Worker with progressive_delivery"
;;

let test_fn_with_progressive_delivery_still_no_op () =
  let spec =
    { base_spec with
      primitive = Sol_cli_deployment_plan.Fn
    ; progressive_delivery = Some (Sol_cli_toml.Canary { steps = [] })
    }
  in
  match Sol_cli_rollback.rollback_target_of_service spec with
  | Sol_cli_rollback.No_op _ -> ()
  | _ ->
    Alcotest.fail
      "Fn primitive must always produce No_op regardless of progressive_delivery"
;;

(* ── execute_rollback No_op ─────────────────────────────────────────────── *)

let test_execute_no_op_returns_ok () =
  match Sol_cli_rollback.execute_rollback (Sol_cli_rollback.No_op "test reason") with
  | Ok () -> ()
  | Error e ->
    Alcotest.failf "expected Ok, got error: %s" (Sol_cli_rollback.error_to_string e)
;;

(* ── Plugin_missing error_to_string ─────────────────────────────────────── *)

let test_plugin_missing_error_contains_install_link () =
  let err =
    Sol_cli_rollback.Plugin_missing { namespace = "myapp-payments"; name = "charge-svc" }
  in
  let msg = Sol_cli_rollback.error_to_string err in
  assert (
    let re = Str.regexp "argoproj.github.io" in
    try
      ignore (Str.search_forward re msg 0);
      true
    with
    | Not_found -> false);
  assert (
    let re = Str.regexp "kubectl argo rollouts undo" in
    try
      ignore (Str.search_forward re msg 0);
      true
    with
    | Not_found -> false)
;;

let test_plugin_missing_error_contains_namespace_and_name () =
  let err =
    Sol_cli_rollback.Plugin_missing { namespace = "myapp-payments"; name = "charge-svc" }
  in
  let msg = Sol_cli_rollback.error_to_string err in
  assert (
    let re = Str.regexp "myapp-payments" in
    try
      ignore (Str.search_forward re msg 0);
      true
    with
    | Not_found -> false);
  assert (
    let re = Str.regexp "charge-svc" in
    try
      ignore (Str.search_forward re msg 0);
      true
    with
    | Not_found -> false)
;;

let test_non_zero_error_to_string () =
  let err =
    Sol_cli_rollback.Non_zero { command = "kubectl rollout undo"; exit_code = 1 }
  in
  let msg = Sol_cli_rollback.error_to_string err in
  assert (
    let re = Str.regexp "kubectl rollout undo" in
    try
      ignore (Str.search_forward re msg 0);
      true
    with
    | Not_found -> false);
  assert (
    let re = Str.regexp "1" in
    try
      ignore (Str.search_forward re msg 0);
      true
    with
    | Not_found -> false)
;;

let () =
  Alcotest.run
    "rollback"
    [ ( "rollback_target_of_service"
      , [ Alcotest.test_case
            "Svc -> Standard_deployment"
            `Quick
            test_svc_gives_standard_deployment
        ; Alcotest.test_case
            "Worker -> Standard_deployment"
            `Quick
            test_worker_gives_standard_deployment
        ; Alcotest.test_case "Fn -> No_op" `Quick test_fn_gives_no_op
        ; Alcotest.test_case
            "canary -> Argo_rollout"
            `Quick
            test_progressive_delivery_gives_argo_rollout
        ; Alcotest.test_case
            "blue_green -> Argo_rollout"
            `Quick
            test_blue_green_gives_argo_rollout
        ; Alcotest.test_case
            "Worker+canary -> Argo_rollout"
            `Quick
            test_worker_with_argo_gives_argo_rollout
        ; Alcotest.test_case
            "Fn+canary still No_op"
            `Quick
            test_fn_with_progressive_delivery_still_no_op
        ] )
    ; ( "execute_rollback"
      , [ Alcotest.test_case "No_op always Ok" `Quick test_execute_no_op_returns_ok ] )
    ; ( "error_to_string"
      , [ Alcotest.test_case
            "Plugin_missing contains install URL"
            `Quick
            test_plugin_missing_error_contains_install_link
        ; Alcotest.test_case
            "Plugin_missing contains names"
            `Quick
            test_plugin_missing_error_contains_namespace_and_name
        ; Alcotest.test_case
            "Non_zero contains command and code"
            `Quick
            test_non_zero_error_to_string
        ] )
    ]
;;
