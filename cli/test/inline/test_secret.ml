let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual
let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

let test_key_validation_accepts_env_style_key () =
  check_bool "valid key" true (Sol_cli_secret.validate_key "DATABASE_URL" = Ok ())
;;

let test_key_validation_rejects_lowercase () =
  match Sol_cli_secret.validate_key "database_url" with
  | Ok () -> Windtrap.fail "lowercase key accepted"
  | Error msg -> check_string "error" "secret key must start with an uppercase letter" msg
;;

let test_key_validation_rejects_hyphen () =
  match Sol_cli_secret.validate_key "API-TOKEN" with
  | Ok () -> Windtrap.fail "hyphenated key accepted"
  | Error msg ->
    check_string
      "error"
      "secret key may contain only uppercase letters, digits, and underscores"
      msg
;;

let test_unit_secret_manifest_has_only_its_explicit_values () =
  let yaml =
    Sol_cli_secret.unit_secret_manifest
      ~namespace:"myapp-payments"
      ~secret_name:"charge-svc-secrets"
      [ "PAYMENT_KEY", "value" ]
  in
  check_bool
    "uses the exact per-unit Secret name"
    true
    (Sol_cli_string.contains ~needle:"name: charge-svc-secrets" yaml);
  check_bool
    "does not write the shared runtime Secret"
    false
    (Sol_cli_string.contains ~needle:"name: sol-secrets" yaml);
  check_bool
    "contains only the selected unit key"
    true
    (Sol_cli_string.contains ~needle:{|PAYMENT_KEY: "value"|} yaml);
  check_bool
    "does not contain a different unit's key"
    false
    (Sol_cli_string.contains ~needle:"OTHER_UNIT_KEY" yaml)
;;

let%test "validation: accepts env style key" =
  test_key_validation_accepts_env_style_key ()
;;

let%test "validation: rejects lowercase" = test_key_validation_rejects_lowercase ()
let%test "validation: rejects hyphen" = test_key_validation_rejects_hyphen ()

let%test "rendering: unit Secret has the exact object and keys" =
  test_unit_secret_manifest_has_only_its_explicit_values ()
;;
