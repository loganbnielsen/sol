(* REFAC-117: `sol alert test`'s payload and send outcome. *)

module T = Sol_cli_alert_test
module J = Yojson.Safe.Util

let alert () =
  match
    T.synthetic_alert ~owner:"ops@x.test" ~runbook_url:"https://rb.test/a" ~now:0.
  with
  | `List [ a ] -> a
  | _ -> Alcotest.fail "one alert expected"
;;

let test_payload () =
  let a = alert () in
  let label k = J.(a |> member "labels" |> member k |> to_string) in
  Alcotest.(check string) "alertname" "SolSyntheticAlert" (label "alertname");
  Alcotest.(check string) "synthetic" "true" (label "synthetic");
  Alcotest.(check string) "owner" "ops@x.test" (label "owner");
  Alcotest.(check string)
    "runbook"
    "https://rb.test/a"
    J.(a |> member "annotations" |> member "runbook_url" |> to_string);
  Alcotest.(check string)
    "startsAt"
    "1970-01-01T00:00:00Z"
    J.(a |> member "startsAt" |> to_string);
  (* No workload taxonomy: a synthetic alert must not look like a real one. *)
  List.iter
    (fun k ->
       Alcotest.(check bool) ("no " ^ k) true J.(a |> member "labels" |> member k = `Null))
    [ "workspace"; "domain"; "service" ]
;;

let test_endpoint () =
  Alcotest.(check string)
    "trimmed base + v2 path"
    "http://127.0.0.1:9093/api/v2/alerts"
    (T.endpoint " http://127.0.0.1:9093 ")
;;

(* A refused connection is Alertmanager being unreachable through curl: a
   Rejected send carrying curl's exit code (7), not an exception or Accepted. *)
let test_send_to_closed_port () =
  match T.send ~url:"http://127.0.0.1:1/api/v2/alerts" ~body:"[]" with
  | T.Rejected { exit_code; _ } ->
    Alcotest.(check int) "curl: couldn't connect" 7 exit_code
  | T.Accepted -> Alcotest.fail "accepted by a closed port"
  | T.Unreachable why -> Alcotest.fail ("curl could not run: " ^ why)
;;

let () =
  Alcotest.run
    "alert_test"
    [ ( "alert_test"
      , [ Alcotest.test_case "payload" `Quick test_payload
        ; Alcotest.test_case "endpoint" `Quick test_endpoint
        ; Alcotest.test_case "send to a closed port" `Quick test_send_to_closed_port
        ] )
    ]
;;
