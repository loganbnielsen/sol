let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)
let contains haystack needle = Sol_cli_string.contains ~needle haystack

let test_key_validation_accepts_env_style_key () =
  check_bool "valid key" true (Sol_cli_secret.validate_key "DATABASE_URL" = Ok ())
;;

let test_key_validation_rejects_lowercase () =
  match Sol_cli_secret.validate_key "database_url" with
  | Ok () -> Alcotest.fail "lowercase key accepted"
  | Error msg -> check_string "error" "secret key must start with an uppercase letter" msg
;;

let test_key_validation_rejects_hyphen () =
  match Sol_cli_secret.validate_key "API-TOKEN" with
  | Ok () -> Alcotest.fail "hyphenated key accepted"
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
  check_bool "manifest names Secret" true (contains yaml "kind: Secret");
  check_bool "manifest has runtime secret name" true (contains yaml "name: sol-secrets");
  check_bool
    "manifest preserves existing encoded key"
    true
    (contains yaml {|API_TOKEN: "ZXhpc3Rpbmc="|});
  check_bool
    "manifest has value for k8s materialization"
    true
    (contains yaml {|DATABASE_URL: "postgres://secret"|})
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
    (contains yaml {|SPECIAL_VALUE: "quote: \"value\"|});
  check_bool "backslashes are escaped" true (contains yaml {|path: C:\\tmp\\db|});
  check_bool "newlines are escaped" true (contains yaml {|db\nnext line"|});
  check_bool
    "existing data is quoted safely"
    true
    (contains yaml {|OLD_VALUE: "base64/with+symbols="|})
;;

let test_redacted_result_hides_value () =
  let out =
    Sol_cli_secret.redacted_result (Sol_cli_secret.Applied [ "myapp-payments" ])
  in
  check_string "redacted output" "secret set in 1 namespace(s)" out;
  check_bool "no secret value" false (contains out "postgres://secret")
;;

let test_list_rejects_empty_namespaces () =
  match
    Sol_cli_secret.list
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace:"myapp"
      ~namespaces:[]
  with
  | Ok _ -> Alcotest.fail "empty namespace list unexpectedly succeeded"
  | Error msg ->
    check_string "no target" "no target namespaces found for this workspace" msg
;;

let () =
  Alcotest.run
    "secret"
    [ ( "validation"
      , [ Alcotest.test_case
            "accepts env style key"
            `Quick
            test_key_validation_accepts_env_style_key
        ; Alcotest.test_case
            "rejects lowercase"
            `Quick
            test_key_validation_rejects_lowercase
        ; Alcotest.test_case "rejects hyphen" `Quick test_key_validation_rejects_hyphen
        ] )
    ; ( "target"
      , [ Alcotest.test_case
            "rejects empty namespace selection"
            `Quick
            test_list_rejects_empty_namespaces
        ] )
    ; ( "rendering"
      , [ Alcotest.test_case
            "k8s materialization manifest"
            `Quick
            test_secret_manifest_contains_value_boundary
        ; Alcotest.test_case
            "yaml escapes special values"
            `Quick
            test_secret_manifest_yaml_escapes_special_values
        ; Alcotest.test_case "redacted result" `Quick test_redacted_result_hides_value
        ] )
    ]
;;
