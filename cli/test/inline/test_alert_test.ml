module T = Sol_cli_alert_test
module J = Yojson.Safe.Util

let alert () =
  match
    T.synthetic_alert ~owner:"ops@x.test" ~runbook_url:"https://rb.test/a" ~now:0.
  with
  | `List [ a ] -> a
  | _ -> Windtrap.fail "one alert expected"
;;

let test_payload () =
  let a = alert () in
  let label k = J.(a |> member "labels" |> member k |> to_string) in
  Windtrap.equal Windtrap.string ~msg:"alertname" "SolSyntheticAlert" (label "alertname");
  Windtrap.equal Windtrap.string ~msg:"synthetic" "true" (label "synthetic");
  Windtrap.equal Windtrap.string ~msg:"owner" "ops@x.test" (label "owner");
  Windtrap.equal
    Windtrap.string
    ~msg:"runbook"
    "https://rb.test/a"
    J.(a |> member "annotations" |> member "runbook_url" |> to_string);
  Windtrap.equal
    Windtrap.string
    ~msg:"startsAt"
    "1970-01-01T00:00:00Z"
    J.(a |> member "startsAt" |> to_string);
  List.iter
    (fun k ->
       Windtrap.equal
         Windtrap.bool
         ~msg:("no " ^ k)
         true
         J.(a |> member "labels" |> member k = `Null))
    [ "workspace"; "domain"; "service" ]
;;

let test_endpoint () =
  Windtrap.equal
    Windtrap.string
    ~msg:"trimmed base + v2 path"
    "http://127.0.0.1:9093/api/v2/alerts"
    (T.endpoint " http://127.0.0.1:9093 ")
;;

let test_send_to_closed_port () =
  match T.send ~url:"http://127.0.0.1:1/api/v2/alerts" ~body:"[]" with
  | T.Rejected { exit_code; _ } ->
    Windtrap.equal Windtrap.int ~msg:"curl: couldn't connect" 7 exit_code
  | T.Accepted -> Windtrap.fail "accepted by a closed port"
  | T.Unreachable why -> Windtrap.fail ("curl could not run: " ^ why)
;;

let test_operation () =
  let cwd = Sys.getcwd () in
  let workspace = Filename.concat (Source_root.find ()) "examples/pluto" in
  Fun.protect
    ~finally:(fun () -> Sys.chdir cwd)
    (fun () ->
       Sys.chdir workspace;
       let target = "pilot/aws/us-east-1" in
       let url = "http://127.0.0.1:1" in
       (match Sol_cli_alert_operation.test target url true with
        | Ok (Dry_run { url; body }) ->
          Windtrap.equal
            Windtrap.string
            ~msg:"destination"
            "http://127.0.0.1:1/api/v2/alerts"
            url;
          Windtrap.equal
            Windtrap.string
            ~msg:"configured owner"
            "pluto-oncall"
            J.(
              Yojson.Safe.from_string body
              |> index 0
              |> member "labels"
              |> member "owner"
              |> to_string)
        | _ -> Windtrap.fail "expected dry-run outcome without sending");
       (match Sol_cli_alert_operation.test "invalid" url true with
        | Error (Invalid_target _) -> ()
        | _ -> Windtrap.fail "expected typed target error");
       (match Sol_cli_alert_operation.test "dev/aws/us-east-1" url true with
        | Error (Invalid_delivery _) -> ()
        | _ -> Windtrap.fail "expected typed delivery error");
       match Sol_cli_alert_operation.test target url false with
       | Error (Rejected { exit_code; _ }) ->
         Windtrap.equal Windtrap.int ~msg:"typed curl rejection" 7 exit_code
       | _ -> Windtrap.fail "expected typed rejection")
;;

let%test "alert_test: operation outcomes" = test_operation ()
let%test "alert_test: payload" = test_payload ()
let%test "alert_test: endpoint" = test_endpoint ()
let%test "alert_test: send to a closed port" = test_send_to_closed_port ()
