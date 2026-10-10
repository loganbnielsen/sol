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

let test_external_secrets_is_not_enabled_for_m1 () =
  expect_error
    "external-secrets before M2"
    "not supported yet"
    (run
       ~emit_to:"out"
       ~backend:"external-secrets"
       ~store_ref:"my-store"
       ~store_kind:"SecretStore"
       ~refresh_interval:"1h"
       ())
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

let%test "secret backend: external-secrets remains disabled until M2" =
  test_external_secrets_is_not_enabled_for_m1 ()
;;

let%test "secret backend: irrelevant dependent flags refuse" =
  test_irrelevant_dependent_flags_refuse ()
;;

let%test "secret backend: an unknown backend refuses" = test_unknown_backend_refuses ()
