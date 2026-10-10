let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual

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
  Windtrap.equal
    Windtrap.bool
    ~msg:"constructor is Local"
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
  | Error msg -> Windtrap.fail ("unexpected error: " ^ msg)
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
  | Error msg -> Windtrap.fail ("unexpected error: " ^ msg)
  | Ok t ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"constructor is Customer_direct"
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
  | Error msg -> Windtrap.fail ("unexpected error: " ^ msg)
  | Ok t ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"constructor is Customer_gitops"
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
  | Ok _ -> Windtrap.fail "expected Error but got Ok"
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
    Windtrap.equal Windtrap.bool ~msg:"error mentions registry" true contains_registry
;;

let test_whitespace_registry_fails () =
  Windtrap.equal
    Windtrap.bool
    ~msg:"whitespace registry fails"
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
  Windtrap.equal
    Windtrap.bool
    ~msg:"mode Local"
    true
    (cfg.mode = Sol_cli_deployment_plan.Local)
;;

let test_to_env_config_customer () =
  match
    Sol_cli_env_target.customer_cloud_defaults
      ~registry:"gcr.io/myproject"
      ~image_tag:"v1.2.3"
      ~emit_to:None
      ()
  with
  | Error msg -> Windtrap.fail ("unexpected error: " ^ msg)
  | Ok t ->
    let cfg = Sol_cli_env_target.to_env_config ~name:"production" t in
    check_string "name" "production" cfg.name;
    Windtrap.equal
      Windtrap.bool
      ~msg:"mode Customer_cloud"
      true
      (cfg.mode = Sol_cli_deployment_plan.Customer_cloud)
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
