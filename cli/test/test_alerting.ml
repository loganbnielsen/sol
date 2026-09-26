let contains needle haystack = Sol_cli_string.contains ~needle haystack
let check_bool = Alcotest.(check bool)

let test_qualified_receiver_types () =
  check_bool
    "webhook is the only maturity-A receiver"
    true
    (Sol_cli_alerting.qualified_receiver_types = [ "webhook" ]);
  check_bool "webhook qualified" true (Sol_cli_alerting.receiver_type_qualified "webhook");
  check_bool
    "case and whitespace insensitive"
    true
    (Sol_cli_alerting.receiver_type_qualified "  WebHook ");
  check_bool
    "pagerduty is an adapter, not the contract"
    false
    (Sol_cli_alerting.receiver_type_qualified "pagerduty")
;;

let test_url_is_routable () =
  check_bool
    "https with host"
    true
    (Sol_cli_alerting.url_is_routable "https://hooks.example.com/sol-alerts");
  check_bool
    "http with host"
    true
    (Sol_cli_alerting.url_is_routable "http://127.0.0.1:9093");
  check_bool
    "bare hostname is not routable"
    false
    (Sol_cli_alerting.url_is_routable "hooks.example.com");
  check_bool "no scheme" false (Sol_cli_alerting.url_is_routable "not-a-url");
  check_bool "scheme with no host" false (Sol_cli_alerting.url_is_routable "https://");
  check_bool
    "scheme with slash host"
    false
    (Sol_cli_alerting.url_is_routable "https:///path");
  check_bool "non-http scheme" false (Sol_cli_alerting.url_is_routable "ftp://host/x")
;;

let test_validate_accepts_a_complete_declaration () =
  match
    Sol_cli_alerting.validate
      ~receiver_type:(Some "webhook")
      ~receiver_url:(Some "https://hooks.example.com/x")
      ~owner:(Some "payments-oncall")
      ~runbook_url:(Some "https://runbooks.example.com/sol")
  with
  | Ok () -> ()
  | Error msg -> Alcotest.fail msg
;;

let test_validate_requires_a_receiver () =
  match
    Sol_cli_alerting.validate
      ~receiver_type:None
      ~receiver_url:(Some "https://hooks.example.com/x")
      ~owner:(Some "o")
      ~runbook_url:(Some "https://r")
  with
  | Ok () -> Alcotest.fail "expected a missing receiver to fail"
  | Error msg -> assert (contains "alert_receiver_type" msg)
;;

let test_validate_rejects_unqualified_receiver () =
  match
    Sol_cli_alerting.validate
      ~receiver_type:(Some "pagerduty")
      ~receiver_url:(Some "https://hooks.example.com/x")
      ~owner:(Some "o")
      ~runbook_url:(Some "https://r")
  with
  | Ok () -> Alcotest.fail "expected an unqualified receiver to fail"
  | Error msg -> assert (contains "qualified" msg)
;;

let test_validate_rejects_unroutable_url () =
  match
    Sol_cli_alerting.validate
      ~receiver_type:(Some "webhook")
      ~receiver_url:(Some "not-a-url")
      ~owner:(Some "o")
      ~runbook_url:(Some "https://r")
  with
  | Ok () -> Alcotest.fail "expected an unroutable URL to fail"
  | Error msg -> assert (contains "routable" msg)
;;

let test_validate_requires_owner () =
  match
    Sol_cli_alerting.validate
      ~receiver_type:(Some "webhook")
      ~receiver_url:(Some "https://hooks.example.com/x")
      ~owner:None
      ~runbook_url:(Some "https://r")
  with
  | Ok () -> Alcotest.fail "expected a missing owner to fail"
  | Error msg -> assert (contains "alert_owner" msg)
;;

let test_validate_requires_runbook () =
  match
    Sol_cli_alerting.validate
      ~receiver_type:(Some "webhook")
      ~receiver_url:(Some "https://hooks.example.com/x")
      ~owner:(Some "o")
      ~runbook_url:None
  with
  | Ok () -> Alcotest.fail "expected a missing runbook to fail"
  | Error msg -> assert (contains "alert_runbook_url" msg)
;;

let () =
  Alcotest.run
    "alerting"
    [ ( "vocabulary"
      , [ Alcotest.test_case
            "qualified receiver types"
            `Quick
            test_qualified_receiver_types
        ; Alcotest.test_case "url routability" `Quick test_url_is_routable
        ] )
    ; ( "validate"
      , [ Alcotest.test_case
            "complete declaration accepted"
            `Quick
            test_validate_accepts_a_complete_declaration
        ; Alcotest.test_case "receiver required" `Quick test_validate_requires_a_receiver
        ; Alcotest.test_case
            "unqualified receiver rejected"
            `Quick
            test_validate_rejects_unqualified_receiver
        ; Alcotest.test_case
            "unroutable url rejected"
            `Quick
            test_validate_rejects_unroutable_url
        ; Alcotest.test_case "owner required" `Quick test_validate_requires_owner
        ; Alcotest.test_case "runbook required" `Quick test_validate_requires_runbook
        ] )
    ]
;;
