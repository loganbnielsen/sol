let check_string = Alcotest.(check string)

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

let test_to_env_config_local () =
  let t = Sol_cli_env_target.local_defaults ~image_tag:"abc123" in
  let cfg = Sol_cli_env_target.to_env_config ~name:"local" t in
  check_string "name" "local" cfg.name;
  check_string "registry" "sol-registry:5000" cfg.registry;
  check_string "image_tag" "abc123" cfg.image_tag;
  Alcotest.(check bool) "mode Local" true (cfg.mode = Sol_cli_deployment_plan.Local)
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
    check_string "name" "production" cfg.name;
    Alcotest.(check bool)
      "mode Customer_cloud"
      true
      (cfg.mode = Sol_cli_deployment_plan.Customer_cloud)
;;

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
    cfg.secret_backend
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
      cfg.secret_backend
;;

let customer_direct_target () =
  match
    Sol_cli_env_target.customer_cloud_defaults
      ~registry:"reg.example.com"
      ~image_tag:"sha"
      ~emit_to:None
      ()
  with
  | Ok t -> t
  | Error msg -> Alcotest.fail msg
;;

let customer_gitops_target () =
  match
    Sol_cli_env_target.customer_cloud_defaults
      ~registry:"reg.example.com"
      ~image_tag:"sha"
      ~emit_to:(Some "manifests")
      ()
  with
  | Ok t -> t
  | Error msg -> Alcotest.fail msg
;;

let backend_is ~expected ?explicit t =
  let actual = Sol_cli_env_target.resolve_secret_backend ?explicit t in
  Alcotest.(check bool)
    (Printf.sprintf
       "expected %s, got %s"
       (Sol_cli_manifest.secret_backend_to_string expected)
       (Sol_cli_manifest.secret_backend_to_string actual))
    true
    (actual = expected)
;;

let test_resolve_direct_without_flag_is_live () =
  backend_is ~expected:Sol_cli_manifest.Kubernetes_live (customer_direct_target ())
;;

let test_resolve_gitops_without_flag_is_placeholder () =
  backend_is ~expected:Sol_cli_manifest.Kubernetes_placeholder (customer_gitops_target ())
;;

let test_resolve_explicit_overrides_inference () =
  backend_is
    ~expected:Sol_cli_manifest.Kubernetes_placeholder
    ~explicit:Sol_cli_manifest.Kubernetes_placeholder
    (customer_direct_target ());
  backend_is
    ~expected:Sol_cli_manifest.Kubernetes_live
    ~explicit:Sol_cli_manifest.Kubernetes_live
    (customer_gitops_target ())
;;

let%test "local_defaults: cluster registry" = test_local_registry ()
let%test "local_defaults: image tag" = test_local_image_tag ()
let%test "local_defaults: Local constructor" = test_local_constructor ()
let%test "customer_cloud_defaults: ECR registry" = test_customer_direct_registry ()

let%test "customer_cloud_defaults: direct constructor" =
  test_customer_direct_constructor ()
;;

let%test "customer_cloud_defaults: gitops constructor" =
  test_customer_gitops_constructor ()
;;

let%test "customer_cloud_defaults: empty registry fails" = test_empty_registry_fails ()

let%test "customer_cloud_defaults: whitespace registry fails" =
  test_whitespace_registry_fails ()
;;

let%test "to_env_config: local" = test_to_env_config_local ()
let%test "to_env_config: customer" = test_to_env_config_customer ()
let%test "default_secret_backend: Local → live" = test_local_default_backend ()

let%test "default_secret_backend: Customer_direct → live" =
  test_customer_direct_default_backend ()
;;

let%test "default_secret_backend: Customer_gitops → placeholder" =
  test_customer_gitops_default_backend ()
;;

let%test "to_env_config secret_backend: Local → live" =
  test_to_env_config_local_backend ()
;;

let%test "to_env_config secret_backend: Customer_gitops → placeholder" =
  test_to_env_config_gitops_backend ()
;;

let%test
    "resolve_secret_backend (INFRA-050): direct deploy with no --secret-backend is live"
  =
  test_resolve_direct_without_flag_is_live ()
;;

let%test
    "resolve_secret_backend (INFRA-050): GitOps with no --secret-backend stays a \
     placeholder"
  =
  test_resolve_gitops_without_flag_is_placeholder ()
;;

let%test
    "resolve_secret_backend (INFRA-050): an explicit --secret-backend overrides the \
     inference"
  =
  test_resolve_explicit_overrides_inference ()
;;
