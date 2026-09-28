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

let test_send_to_closed_port () =
  match T.send ~url:"http://127.0.0.1:1/api/v2/alerts" ~body:"[]" with
  | T.Rejected { exit_code; _ } ->
    Alcotest.(check int) "curl: couldn't connect" 7 exit_code
  | T.Accepted -> Alcotest.fail "accepted by a closed port"
  | T.Unreachable why -> Alcotest.fail ("curl could not run: " ^ why)
;;

let test_operation () =
  let cwd = Sys.getcwd () in
  let workspace =
    if Sys.file_exists "examples/pluto/sol.yml"
    then "examples/pluto"
    else "../../../../examples/pluto"
  in
  Fun.protect
    ~finally:(fun () -> Sys.chdir cwd)
    (fun () ->
       Sys.chdir workspace;
       let target = "pilot/aws/us-east-1" in
       let url = "http://127.0.0.1:1" in
       (match Sol_cli_alert_operation.test target url true with
        | Ok (Dry_run { url; body }) ->
          Alcotest.(check string) "destination" "http://127.0.0.1:1/api/v2/alerts" url;
          Alcotest.(check string)
            "configured owner"
            "pluto-oncall"
            J.(
              Yojson.Safe.from_string body
              |> index 0
              |> member "labels"
              |> member "owner"
              |> to_string)
        | _ -> Alcotest.fail "expected dry-run outcome without sending");
       (match Sol_cli_alert_operation.test "invalid" url true with
        | Error (Invalid_target _) -> ()
        | _ -> Alcotest.fail "expected typed target error");
       (match Sol_cli_alert_operation.test "dev/aws/us-east-1" url true with
        | Error (Invalid_delivery _) -> ()
        | _ -> Alcotest.fail "expected typed delivery error");
       match Sol_cli_alert_operation.test target url false with
       | Error (Rejected { exit_code; _ }) ->
         Alcotest.(check int) "typed curl rejection" 7 exit_code
       | _ -> Alcotest.fail "expected typed rejection")
;;

let () =
  Alcotest.run
    "alert_test"
    [ ( "alert_test"
      , [ Alcotest.test_case "operation outcomes" `Quick test_operation
        ; Alcotest.test_case "payload" `Quick test_payload
        ; Alcotest.test_case "endpoint" `Quick test_endpoint
        ; Alcotest.test_case "send to a closed port" `Quick test_send_to_closed_port
        ] )
    ]
;;
