open Result.Syntax

type test_outcome =
  | Dry_run of
      { url : string
      ; body : string
      }
  | Accepted of { url : string }

type test_error =
  | Invalid_target of Sol_cli_config.error
  | Invalid_delivery of string
  | Rejected of
      { exit_code : int
      ; stderr : string
      }
  | Unreachable of string

let test target alertmanager_url dry_run =
  let* cfg =
    Sol_cli_config.load_for_target ~target |> Result.map_error (fun e -> Invalid_target e)
  in
  let target_cfg = cfg.target in
  let* () =
    Sol_cli_alerting.validate
      ~receiver_type:target_cfg.alert_receiver_type
      ~receiver_url:target_cfg.alert_receiver_url
      ~owner:target_cfg.alert_owner
      ~runbook_url:target_cfg.alert_runbook_url
    |> Result.map_error (fun reason -> Invalid_delivery reason)
  in
  let body =
    Sol_cli_alert_test.synthetic_alert
      ~owner:(Option.value target_cfg.alert_owner ~default:"")
      ~runbook_url:(Option.value target_cfg.alert_runbook_url ~default:"")
      ~now:(Unix.gettimeofday ())
    |> Yojson.Safe.to_string
  in
  let url = Sol_cli_alert_test.endpoint alertmanager_url in
  if dry_run
  then Ok (Dry_run { url; body })
  else (
    match Sol_cli_alert_test.send ~url ~body with
    | Accepted -> Ok (Accepted { url })
    | Rejected { exit_code; stderr } -> Error (Rejected { exit_code; stderr })
    | Unreachable reason -> Error (Unreachable reason))
;;
