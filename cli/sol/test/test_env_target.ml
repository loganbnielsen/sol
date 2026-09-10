let check_string = Alcotest.(check string)

(* ── local_defaults ──────────────────────────────────────────────────────── *)

let test_local_registry () =
  let t = Sol_cli_env_target.local_defaults ~image_tag:"abc123" in
  check_string "cluster registry" "sol-registry:5000" (Sol_cli_env_target.registry t)
;;

let test_local_image_tag () =
  let t = Sol_cli_env_target.local_defaults ~image_tag:"abc123" in
  check_string "image tag preserved" "abc123" (Sol_cli_env_target.image_tag t)
;;

let test_local_constructor () =
  let t = Sol_cli_env_target.local_defaults ~image_tag:"dev" in
  Alcotest.(check bool)
    "constructor is Local"
    true
    (match t with
     | Sol_cli_env_target.Local _ -> true
     | _ -> false)
;;

(* ── customer_cloud_defaults — direct mode ───────────────────────────────── *)

let test_customer_direct_registry () =
  match
    Sol_cli_env_target.customer_cloud_defaults
      ~registry:"123456789.dkr.ecr.us-east-1.amazonaws.com"
      ~image_tag:"sha-deadbeef"
      ~emit_to:None
      ()
  with
  | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)
  | Ok t ->
    check_string
      "ECR registry"
      "123456789.dkr.ecr.us-east-1.amazonaws.com"
      (Sol_cli_env_target.registry t)
;;

let test_customer_direct_constructor () =
  match
    Sol_cli_env_target.customer_cloud_defaults
      ~registry:"reg"
      ~image_tag:"tag"
      ~emit_to:None
      ()
  with
  | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)
  | Ok t ->
    Alcotest.(check bool)
      "constructor is Customer_direct"
      true
      (match t with
       | Sol_cli_env_target.Customer_direct _ -> true
       | _ -> false)
;;

(* ── customer_cloud_defaults — gitops mode ───────────────────────────────── *)

let test_customer_gitops_constructor () =
  match
    Sol_cli_env_target.customer_cloud_defaults
      ~registry:"reg"
      ~image_tag:"tag"
      ~emit_to:(Some "/tmp/manifests")
      ()
  with
  | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)
  | Ok t ->
    Alcotest.(check bool)
      "constructor is Customer_gitops"
      true
      (match t with
       | Sol_cli_env_target.Customer_gitops _ -> true
       | _ -> false)
;;

(* ── empty/whitespace registry rejected at construction ─────────────────── *)

let test_empty_registry_fails () =
  match
    Sol_cli_env_target.customer_cloud_defaults
      ~registry:""
      ~image_tag:"sha-abc"
      ~emit_to:None
      ()
  with
  | Ok _ -> Alcotest.fail "expected Error but got Ok"
  | Error msg ->
    let contains_registry =
      let needle = "registry" in
      let nlen = String.length needle in
      let mlen = String.length msg in
      let found = ref false in
      for i = 0 to mlen - nlen do
        if String.sub msg i nlen = needle then found := true
      done;
      !found
    in
    Alcotest.(check bool) "error mentions registry" true contains_registry
;;

let test_whitespace_registry_fails () =
  Alcotest.(check bool)
    "whitespace registry fails"
    true
    (Result.is_error
       (Sol_cli_env_target.customer_cloud_defaults
          ~registry:"   "
          ~image_tag:"sha-abc"
          ~emit_to:None
          ()))
;;

(* ── to_env_config ───────────────────────────────────────────────────────── *)

let test_to_env_config_local () =
  let t = Sol_cli_env_target.local_defaults ~image_tag:"abc123" in
  let cfg = Sol_cli_env_target.to_env_config ~name:"local" t in
  check_string "name" "local" cfg.Sol_cli_deployment_plan.name;
  check_string "registry" "sol-registry:5000" cfg.Sol_cli_deployment_plan.registry;
  check_string "image_tag" "abc123" cfg.Sol_cli_deployment_plan.image_tag;
  Alcotest.(check bool)
    "mode Local"
    true
    (cfg.Sol_cli_deployment_plan.mode = Sol_cli_deployment_plan.Local)
;;

let test_to_env_config_customer () =
  match
    Sol_cli_env_target.customer_cloud_defaults
      ~registry:"gcr.io/myproject"
      ~image_tag:"v1.2.3"
      ~emit_to:None
      ()
  with
  | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)
  | Ok t ->
    let cfg = Sol_cli_env_target.to_env_config ~name:"production" t in
    check_string "name" "production" cfg.Sol_cli_deployment_plan.name;
    Alcotest.(check bool)
      "mode Customer_cloud"
      true
      (cfg.Sol_cli_deployment_plan.mode = Sol_cli_deployment_plan.Customer_cloud)
;;

(* ── default_secret_backend ──────────────────────────────────────────────── *)

let check_backend label expected actual =
  Alcotest.(check string)
    label
    (Sol_cli_manifest.secret_backend_to_string expected)
    (Sol_cli_manifest.secret_backend_to_string actual)
;;

let test_local_default_backend () =
  let t = Sol_cli_env_target.local_defaults ~image_tag:"dev" in
  check_backend
    "Local → Kubernetes_live"
    Sol_cli_manifest.Kubernetes_live
    (Sol_cli_env_target.default_secret_backend t)
;;

let test_customer_direct_default_backend () =
  match
    Sol_cli_env_target.customer_cloud_defaults
      ~registry:"reg"
      ~image_tag:"tag"
      ~emit_to:None
      ()
  with
  | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)
  | Ok t ->
    check_backend
      "Customer_direct → Kubernetes_live"
      Sol_cli_manifest.Kubernetes_live
      (Sol_cli_env_target.default_secret_backend t)
;;

let test_customer_gitops_default_backend () =
  match
    Sol_cli_env_target.customer_cloud_defaults
      ~registry:"reg"
      ~image_tag:"tag"
      ~emit_to:(Some "/tmp/manifests")
      ()
  with
  | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)
  | Ok t ->
    check_backend
      "Customer_gitops → Kubernetes_placeholder"
      Sol_cli_manifest.Kubernetes_placeholder
      (Sol_cli_env_target.default_secret_backend t)
;;

let test_to_env_config_local_backend () =
  let t = Sol_cli_env_target.local_defaults ~image_tag:"dev" in
  let cfg = Sol_cli_env_target.to_env_config ~name:"local" t in
  check_backend
    "to_env_config Local → Kubernetes_live"
    Sol_cli_manifest.Kubernetes_live
    cfg.Sol_cli_deployment_plan.secret_backend
;;

let test_to_env_config_gitops_backend () =
  match
    Sol_cli_env_target.customer_cloud_defaults
      ~registry:"reg"
      ~image_tag:"tag"
      ~emit_to:(Some "/tmp/manifests")
      ()
  with
  | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)
  | Ok t ->
    let cfg = Sol_cli_env_target.to_env_config ~name:"prod" t in
    check_backend
      "to_env_config Customer_gitops → Kubernetes_placeholder"
      Sol_cli_manifest.Kubernetes_placeholder
      cfg.Sol_cli_deployment_plan.secret_backend
;;

let () =
  Alcotest.run
    "env_target"
    [ ( "local_defaults"
      , [ Alcotest.test_case "cluster registry" `Quick test_local_registry
        ; Alcotest.test_case "image tag" `Quick test_local_image_tag
        ; Alcotest.test_case "Local constructor" `Quick test_local_constructor
        ] )
    ; ( "customer_cloud_defaults"
      , [ Alcotest.test_case "ECR registry" `Quick test_customer_direct_registry
        ; Alcotest.test_case "direct constructor" `Quick test_customer_direct_constructor
        ; Alcotest.test_case "gitops constructor" `Quick test_customer_gitops_constructor
        ; Alcotest.test_case "empty registry fails" `Quick test_empty_registry_fails
        ; Alcotest.test_case
            "whitespace registry fails"
            `Quick
            test_whitespace_registry_fails
        ] )
    ; ( "to_env_config"
      , [ Alcotest.test_case "local" `Quick test_to_env_config_local
        ; Alcotest.test_case "customer" `Quick test_to_env_config_customer
        ] )
    ; ( "default_secret_backend"
      , [ Alcotest.test_case "Local → live" `Quick test_local_default_backend
        ; Alcotest.test_case
            "Customer_direct → live"
            `Quick
            test_customer_direct_default_backend
        ; Alcotest.test_case
            "Customer_gitops → placeholder"
            `Quick
            test_customer_gitops_default_backend
        ] )
    ; ( "to_env_config secret_backend"
      , [ Alcotest.test_case "Local → live" `Quick test_to_env_config_local_backend
        ; Alcotest.test_case
            "Customer_gitops → placeholder"
            `Quick
            test_to_env_config_gitops_backend
        ] )
    ]
;;
