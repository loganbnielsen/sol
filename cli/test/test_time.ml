(* REFAC-119: each timestamp format Sol writes, pinned for a fixed instant.
   1790436649.75 is 2026-09-26 15:30:49.75 UTC; the fraction is truncated. *)

let instant = 1790436649.75

let test_formats () =
  Alcotest.(check string) "rfc3339" "2026-09-26T15:30:49Z" (Sol_cli_time.rfc3339 instant);
  Alcotest.(check string) "compact" "20260926T153049Z" (Sol_cli_time.compact instant);
  Alcotest.(check string)
    "compact_lower"
    "20260926t153049z"
    (Sol_cli_time.compact_lower instant)
;;

(* The callers keep their exact shapes. *)
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

(* Positive control: the epoch is not special-cased away. *)
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
