(* sol alert — OBS-043's alert-to-owner response loop.

   `sol alert test` sends one synthetic alert through the target's configured
   route so the team can prove delivery without triggering a real incident. It
   validates the same provider-neutral contract `sol deploy`'s preflight does
   (receiver type, endpoint, owner, runbook), then injects the alert into
   Alertmanager's v2 API, which routes it exactly like a fired rule.

   What this proves is that the *mechanism* works: the Alertmanager route is
   reachable and accepts the alert. Whether it reaches and is acknowledged by the
   named human is HARDEN-002's live evidence — DEC-026 §8 and OBS-043 both insist
   a delivered-and-acknowledged test is the only thing that satisfies the
   guarantee, and a CLI invocation alone cannot assert someone was paged. *)

let timestamp_now () = Sol_cli_time.rfc3339 (Unix.gettimeofday ())

(* The synthetic alert deliberately carries no workspace/domain/service labels:
   the goal is to prove the route regardless of which workload would have fired,
   and a fabricated taxonomy label would be indistinguishable from a real alert
   in the receiver's history. `synthetic` makes that explicit to whoever is on
   call. *)
let synthetic_alert ~owner ~runbook_url =
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
        ; "startsAt", `String (timestamp_now ())
        ]
    ]
;;

let run_test target_opt alertmanager_url dry_run () =
  let target =
    match target_opt with
    | Some t -> t
    | None ->
      Printf.eprintf
        "error: `sol alert test` needs a target — pass --target \
         <env>/<provider>/<region>, the file that declares the receiver/owner/runbook \
         contract.\n";
      exit 1
  in
  match Sol_cli_config.load_for_target ~target with
  | Error e ->
    Printf.eprintf "%s\n" (Sol_cli_config.error_to_string e);
    exit 1
  | Ok cfg ->
    let target_cfg = cfg.Sol_cli_config.target in
    (match
       Sol_cli_alerting.validate
         ~receiver_type:target_cfg.Sol_cli_config.alert_receiver_type
         ~receiver_url:target_cfg.Sol_cli_config.alert_receiver_url
         ~owner:target_cfg.Sol_cli_config.alert_owner
         ~runbook_url:target_cfg.Sol_cli_config.alert_runbook_url
     with
     | Error reason ->
       Printf.eprintf
         "error: target %s does not satisfy the alert-delivery contract: %s\n"
         target
         reason;
       exit 2
     | Ok () ->
       let owner = Option.value target_cfg.alert_owner ~default:"" in
       let runbook_url = Option.value target_cfg.alert_runbook_url ~default:"" in
       let body = Yojson.Safe.to_string (synthetic_alert ~owner ~runbook_url) in
       let url = String.trim alertmanager_url ^ "/api/v2/alerts" in
       if dry_run
       then (
         Printf.printf "Would POST to %s:\n%s\n" url body;
         Printf.printf
           "\n\
            (dry run: nothing was sent; delivered-and-acknowledged evidence is \
            HARDEN-002's)\n")
       else (
         Printf.printf "Sending a synthetic alert through %s ...\n%!" url;
         match
           Sol_cli_process.run
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
         | Ok r when r.Sol_cli_process.exit_code = 0 ->
           Printf.printf
             "Alertmanager accepted the synthetic alert.\n\n\
              This proves the route is configured and reachable. Confirm the named owner \
              received and acknowledged it: that delivered-and-acknowledged result is \
              the HARDEN-002 evidence, not this command's exit status.\n"
         | Ok r ->
           Printf.eprintf
             "error: Alertmanager rejected the synthetic alert (curl exit %d).\n%s\n"
             r.Sol_cli_process.exit_code
             (String.trim r.Sol_cli_process.stderr);
           Printf.eprintf
             "Is the port-forward up? e.g. `kubectl -n monitoring port-forward \
              svc/prometheus-alertmanager 9093:9093`.\n";
           exit 1
         | Error e ->
           Printf.eprintf
             "error: could not run curl: %s\n"
             (Sol_cli_process.error_to_string e);
           exit 1))
;;

open Cmdliner

let target_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "target" ]
        ~docv:"ENV/PROVIDER/REGION"
        ~doc:
          "The production target whose alert route to exercise (e.g. \
           `pilot/aws/us-east-1`). Required: the target file is where the \
           receiver/owner/runbook contract is declared.")
;;

let alertmanager_url_arg =
  Arg.(
    value
    & opt string "http://127.0.0.1:9093"
    & info
        [ "alertmanager-url" ]
        ~docv:"URL"
        ~doc:
          "Alertmanager base URL. Defaults to the conventional local port-forward \
           (`kubectl -n monitoring port-forward svc/prometheus-alertmanager 9093:9093`).")
;;

let dry_run_arg =
  Arg.(
    value
    & flag
    & info
        [ "dry-run" ]
        ~doc:"Print the synthetic alert and where it would go, without sending it.")
;;

let test_cmd =
  let doc = "Send a synthetic alert through the target's configured route" in
  let man =
    [ `S Manpage.s_description
    ; `P
        "Validates the target's alert-delivery contract (receiver type, endpoint, owner, \
         runbook) and injects one synthetic alert into Alertmanager, which routes it \
         like a fired rule. Nothing pages until the target declares a receiver; the \
         mechanism is proven locally, the delivered-and-acknowledged result is \
         HARDEN-002's live evidence."
    ]
  in
  Cmd.v
    (Cmd.info "test" ~doc ~man)
    Term.(const run_test $ target_arg $ alertmanager_url_arg $ dry_run_arg $ const ())
;;

let cmd =
  Cmd.group
    (Cmd.info "alert" ~doc:"Exercise the alert-to-owner response loop")
    [ test_cmd ]
;;
