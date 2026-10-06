let run ?emit_to ?backend ?store_ref ?store_kind ?key_prefix ?refresh_interval () =
  Sol_cli_secret_backend.emission_backend
    ~emit_to
    ~backend
    ~store_ref
    ~store_kind
    ~key_prefix
    ~refresh_interval
;;

let expect_error label needle = function
  | Ok _ -> Windtrap.fail (label ^ ": expected a refusal, got a backend")
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:(label ^ ": names the problem")
      true
      (Sol_cli_string.contains ~needle message)
;;

let external_secrets label = function
  | Ok
      (Some
         (Sol_cli_manifest.External_secrets
            { store_kind; key_prefix; refresh_interval; _ })) ->
    store_kind, key_prefix, refresh_interval
  | Ok _ -> Windtrap.fail (label ^ ": expected an External_secrets backend")
  | Error message -> Windtrap.fail (label ^ ": " ^ message)
;;

let test_omitted_lets_the_destination_decide () =
  match run () with
  | Ok None -> ()
  | Ok (Some backend) ->
    Windtrap.fail
      ("an omitted backend resolved to "
       ^ Sol_cli_manifest.secret_backend_to_string backend)
  | Error message -> Windtrap.fail message
;;

let test_named_backends () =
  Windtrap.equal
    Windtrap.string
    ~msg:"placeholder"
    "kubernetes-placeholder"
    (match run ~backend:"kubernetes-placeholder" () with
     | Ok (Some backend) -> Sol_cli_manifest.secret_backend_to_string backend
     | _ -> "unexpected");
  Windtrap.equal
    Windtrap.string
    ~msg:"live"
    "kubernetes-live"
    (match run ~backend:"kubernetes-live" () with
     | Ok (Some backend) -> Sol_cli_manifest.secret_backend_to_string backend
     | _ -> "unexpected")
;;

let test_external_secrets_requires_a_gitops_emission_mode () =
  expect_error
    "external-secrets without --emit-to"
    "--emit-to"
    (run ~backend:"external-secrets" ())
;;

let test_external_secrets_requires_a_store_ref () =
  expect_error
    "external-secrets without a store reference"
    "--secret-store-ref is required"
    (run ~emit_to:"out" ~backend:"external-secrets" ())
;;

let test_external_secrets_defaults () =
  let store_kind, key_prefix, refresh_interval =
    external_secrets
      "external-secrets defaults"
      (run ~emit_to:"out" ~backend:"external-secrets" ~store_ref:"my-store" ())
  in
  Windtrap.equal
    Windtrap.string
    ~msg:"default store kind"
    "ClusterSecretStore"
    (Sol_cli_manifest.secret_store_kind_to_string store_kind);
  Windtrap.equal Windtrap.string ~msg:"default key prefix" "" key_prefix;
  Windtrap.equal Windtrap.string ~msg:"default interval" "1h" refresh_interval
;;

let test_secret_store_kind_is_typed () =
  let store_kind, _, _ =
    external_secrets
      "namespace-scoped store"
      (run
         ~emit_to:"out"
         ~backend:"external-secrets"
         ~store_ref:"my-store"
         ~store_kind:"SecretStore"
         ())
  in
  Windtrap.equal
    Windtrap.string
    ~msg:"SecretStore"
    "SecretStore"
    (Sol_cli_manifest.secret_store_kind_to_string store_kind)
;;

let test_unknown_store_kind_refuses () =
  expect_error
    "unknown store kind"
    "unknown secret store kind"
    (run
       ~emit_to:"out"
       ~backend:"external-secrets"
       ~store_ref:"my-store"
       ~store_kind:"ConfigMap"
       ())
;;

let test_malformed_refresh_interval_refuses () =
  List.iter
    (fun raw ->
       expect_error
         (Printf.sprintf "interval %S" raw)
         "not a duration"
         (run
            ~emit_to:"out"
            ~backend:"external-secrets"
            ~store_ref:"my-store"
            ~refresh_interval:raw
            ()))
    [ "soon"; "1"; "1x"; "1h30"; "1 h" ]
;;

let test_supported_refresh_intervals () =
  List.iter
    (fun raw ->
       let _, _, refresh_interval =
         external_secrets
           (Printf.sprintf "interval %S" raw)
           (run
              ~emit_to:"out"
              ~backend:"external-secrets"
              ~store_ref:"my-store"
              ~refresh_interval:raw
              ())
       in
       Windtrap.equal Windtrap.string ~msg:raw raw refresh_interval)
    [ "1h"; "30m"; "5m"; "1h30m"; "500ms"; "90s"; "0" ]
;;

let test_irrelevant_dependent_flags_refuse () =
  expect_error
    "placeholder with a store reference"
    "only apply with --secret-backend=external-secrets"
    (run ~backend:"kubernetes-placeholder" ~store_ref:"my-store" ());
  expect_error
    "omitted backend with a refresh interval"
    "only apply with --secret-backend=external-secrets"
    (run ~refresh_interval:"1h" ());
  expect_error
    "live with a key prefix"
    "only apply with --secret-backend=external-secrets"
    (run ~backend:"kubernetes-live" ~key_prefix:"x/" ())
;;

let test_unknown_backend_refuses () =
  expect_error
    "unknown backend"
    "unknown --secret-backend value"
    (run ~backend:"vault" ())
;;

let%test "secret backend: omitted lets the destination decide" =
  test_omitted_lets_the_destination_decide ()
;;

let%test "secret backend: named backends" = test_named_backends ()

let%test "secret backend: external-secrets requires --emit-to" =
  test_external_secrets_requires_a_gitops_emission_mode ()
;;

let%test "secret backend: external-secrets requires a store reference" =
  test_external_secrets_requires_a_store_ref ()
;;

let%test "secret backend: external-secrets defaults" = test_external_secrets_defaults ()
let%test "secret backend: the store kind is typed" = test_secret_store_kind_is_typed ()

let%test "secret backend: an unknown store kind refuses" =
  test_unknown_store_kind_refuses ()
;;

let%test "secret backend: a malformed refresh interval refuses" =
  test_malformed_refresh_interval_refuses ()
;;

let%test "secret backend: the supported refresh interval syntax is kept" =
  test_supported_refresh_intervals ()
;;

let%test "secret backend: irrelevant dependent flags refuse" =
  test_irrelevant_dependent_flags_refuse ()
;;

let%test "secret backend: an unknown backend refuses" = test_unknown_backend_refuses ()
