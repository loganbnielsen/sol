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

let test_secret_manifest_contains_value_boundary () =
  let yaml =
    Sol_cli_secret.secret_manifest
      ~existing_data:[ "API_TOKEN", "ZXhpc3Rpbmc=" ]
      ~namespace:"myapp-payments"
      ~key:"DATABASE_URL"
      ~value:"postgres://secret"
  in
  check_bool
    "manifest names Secret"
    true
    (Sol_cli_string.contains ~needle:"kind: Secret" yaml);
  check_bool
    "manifest has runtime secret name"
    true
    (Sol_cli_string.contains ~needle:"name: sol-secrets" yaml);
  check_bool
    "manifest preserves existing encoded key"
    true
    (Sol_cli_string.contains ~needle:{|API_TOKEN: "ZXhpc3Rpbmc="|} yaml);
  check_bool
    "manifest has value for k8s materialization"
    true
    (Sol_cli_string.contains ~needle:{|DATABASE_URL: "postgres://secret"|} yaml)
;;

let test_secret_manifest_yaml_escapes_special_values () =
  let yaml =
    Sol_cli_secret.secret_manifest
      ~existing_data:[ "OLD_VALUE", "base64/with+symbols=" ]
      ~namespace:"myapp-payments"
      ~key:"SPECIAL_VALUE"
      ~value:"quote: \"value\", path: C:\\tmp\\db\nnext line"
  in
  check_bool
    "quotes are escaped"
    true
    (Sol_cli_string.contains ~needle:{|SPECIAL_VALUE: "quote: \"value\"|} yaml);
  check_bool
    "backslashes are escaped"
    true
    (Sol_cli_string.contains ~needle:{|path: C:\\tmp\\db|} yaml);
  check_bool
    "newlines are escaped"
    true
    (Sol_cli_string.contains ~needle:{|db\nnext line"|} yaml);
  check_bool
    "existing data is quoted safely"
    true
    (Sol_cli_string.contains ~needle:{|OLD_VALUE: "base64/with+symbols="|} yaml)
;;

let test_redacted_result_hides_value () =
  let out =
    Sol_cli_secret.redacted_result (Sol_cli_secret.Applied [ "myapp-payments" ])
  in
  check_string "redacted output" "secret set in 1 namespace(s)" out;
  check_bool
    "no secret value"
    false
    (Sol_cli_string.contains ~needle:"postgres://secret" out)
;;

let test_list_rejects_empty_namespaces () =
  match
    Sol_cli_secret.list
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~namespaces:[]
  with
  | Ok _ -> Windtrap.fail "empty namespace list unexpectedly succeeded"
  | Error msg ->
    check_string "no target" "no target namespaces found for this workspace" msg
;;

let%test "validation: accepts env style key" =
  test_key_validation_accepts_env_style_key ()
;;

let%test "validation: rejects lowercase" = test_key_validation_rejects_lowercase ()
let%test "validation: rejects hyphen" = test_key_validation_rejects_hyphen ()

let%test "target: rejects empty namespace selection" =
  test_list_rejects_empty_namespaces ()
;;

let%test "rendering: k8s materialization manifest" =
  test_secret_manifest_contains_value_boundary ()
;;

let%test "rendering: yaml escapes special values" =
  test_secret_manifest_yaml_escapes_special_values ()
;;

let%test "rendering: redacted result" = test_redacted_result_hides_value ()
