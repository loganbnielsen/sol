let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)
let check_mode label expected actual = check_bool label true (actual = Ok expected)

let contains haystack needle =
  let hl = String.length haystack
  and nl = String.length needle in
  if nl = 0
  then true
  else if nl > hl
  then false
  else (
    let found = ref false in
    for i = 0 to hl - nl do
      if (not !found) && String.sub haystack i nl = needle then found := true
    done;
    !found)
;;

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

let test_mode_of_env_accepts_hosted_aliases () =
  List.iter
    (fun env -> check_mode env Sol_cli_secret.Sol_hosted (Sol_cli_secret.mode_of_env env))
    [ "hosted"; "sol_hosted"; "sol-hosted" ]
;;

let test_mode_of_env_accepts_local_aliases () =
  List.iter
    (fun env -> check_mode env Sol_cli_secret.Local (Sol_cli_secret.mode_of_env env))
    [ "local"; "dev" ]
;;

let test_mode_of_env_accepts_customer_cloud_aliases () =
  List.iter
    (fun env ->
       check_mode env Sol_cli_secret.Customer_cloud (Sol_cli_secret.mode_of_env env))
    [ "cloud"; "customer_cloud"; "customer-cloud" ]
;;

let test_mode_of_env_rejects_unknown () =
  match Sol_cli_secret.mode_of_env "staging" with
  | Ok _ -> Alcotest.fail "unknown env accepted"
  | Error msg ->
    check_string
      "error"
      "unknown secret environment \"staging\"; expected one of: hosted, sol_hosted, \
       sol-hosted, local, dev, cloud, customer_cloud, customer-cloud"
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

let test_hosted_stub_boundary () =
  match
    Sol_cli_secret.set
      ~env:"hosted"
      ~workspace:"myapp"
      ~namespaces:[ "myapp-payments" ]
      ~key:"DATABASE_URL"
      ~value:"postgres://secret"
  with
  | Ok _ -> Alcotest.fail "hosted set unexpectedly succeeded"
  | Error msg ->
    check_string
      "hosted boundary"
      "hosted secret management will use the Sol control-plane API; no hosted endpoint \
       is configured yet"
      msg
;;

let test_list_rejects_unknown_env () =
  match
    Sol_cli_secret.list ~env:"staging" ~workspace:"myapp" ~namespaces:[ "myapp-payments" ]
  with
  | Ok _ -> Alcotest.fail "unknown env list unexpectedly succeeded"
  | Error msg ->
    check_string
      "unknown env"
      "unknown secret environment \"staging\"; expected one of: hosted, sol_hosted, \
       sol-hosted, local, dev, cloud, customer_cloud, customer-cloud"
      msg
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
    ; ( "env"
      , [ Alcotest.test_case
            "accepts hosted aliases"
            `Quick
            test_mode_of_env_accepts_hosted_aliases
        ; Alcotest.test_case
            "accepts local aliases"
            `Quick
            test_mode_of_env_accepts_local_aliases
        ; Alcotest.test_case
            "accepts customer cloud aliases"
            `Quick
            test_mode_of_env_accepts_customer_cloud_aliases
        ; Alcotest.test_case
            "rejects unknown parser input"
            `Quick
            test_mode_of_env_rejects_unknown
        ; Alcotest.test_case
            "rejects unknown operation env"
            `Quick
            test_list_rejects_unknown_env
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
    ; "hosted", [ Alcotest.test_case "stub boundary" `Quick test_hosted_stub_boundary ]
    ]
;;
