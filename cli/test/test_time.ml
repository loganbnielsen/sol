let instant = 1790436649.75

let test_formats () =
  Alcotest.(check string) "rfc3339" "2026-09-26T15:30:49Z" (Sol_cli_time.rfc3339 instant);
  Alcotest.(check string) "compact" "20260926T153049Z" (Sol_cli_time.compact instant);
  Alcotest.(check string)
    "compact_lower"
    "20260926t153049z"
    (Sol_cli_time.compact_lower instant)
;;

let test_callers () =
  Alcotest.(check string)
    "run id"
    "cloud-apply-20260926T153049Z-42"
    (Sol_cli_run_log.generate_run_id ~prefix:"cloud-apply" ~now:instant ~pid:42);
  Alcotest.(check string)
    "deployment record time"
    "2026-09-26T15:30:49Z"
    (Sol_cli_deployment.rfc3339_utc instant)
;;

let test_epoch () =
  Alcotest.(check string) "epoch" "1970-01-01T00:00:00Z" (Sol_cli_time.rfc3339 0.)
;;

let () =
  Alcotest.run
    "time"
    [ ( "formats"
      , [ Alcotest.test_case "each format" `Quick test_formats
        ; Alcotest.test_case "callers keep their shapes" `Quick test_callers
        ; Alcotest.test_case "epoch" `Quick test_epoch
        ] )
    ]
;;
