let synthetic_alert ~owner ~runbook_url ~now =
  `List
    [ `Assoc
        [ ( "labels"
          , `Assoc
              [ "alertname", `String "SolSyntheticAlert"
              ; "severity", `String "warning"
              ; "synthetic", `String "true"
              ; "owner", `String owner
              ] )
        ; ( "annotations"
          , `Assoc
              [ ( "summary"
                , `String
                    "Synthetic Sol alert: confirms the production alert route reaches \
                     its named owner" )
              ; ( "description"
                , `String
                    "Sent by `sol alert test`. No real incident occurred. Use this to \
                     prove the configured alert-delivery route end to end; HARDEN-002 \
                     records the delivered-and-acknowledged result." )
              ; "runbook_url", `String runbook_url
              ] )
        ; "startsAt", `String (Sol_cli_time.rfc3339 now)
        ]
    ]
;;

let endpoint base_url = String.trim base_url ^ "/api/v2/alerts"

type outcome =
  | Accepted
  | Rejected of
      { exit_code : int
      ; stderr : string
      }
  | Unreachable of string

let send ~url ~body =
  match
    Sol_cli_process.run_ok
      (Sol_cli_process.cmd
         [ "curl"
         ; "-sS"
         ; "-f"
         ; "-X"
         ; "POST"
         ; "-H"
         ; "Content-Type: application/json"
         ; "--data"
         ; body
         ; url
         ])
  with
  | Ok () -> Accepted
  | Error (Sol_cli_process.Non_zero r) ->
    Rejected { exit_code = r.exit_code; stderr = String.trim r.stderr }
  | Error e -> Unreachable (Sol_cli_process.error_to_string e)
;;
