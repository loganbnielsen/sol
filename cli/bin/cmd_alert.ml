open Sol_cli_alert_operation

let run_test target alertmanager_url dry_run =
  match test target alertmanager_url dry_run with
  | Ok (Dry_run { url; body }) ->
    Printf.printf "Would POST to %s:\n%s\n" url body;
    Printf.printf
      "\n\
       (dry run: nothing was sent; delivered-and-acknowledged evidence is HARDEN-002's)\n";
    Ok ()
  | Ok (Accepted { url }) ->
    Printf.printf "Sent a synthetic alert through %s.\n" url;
    Printf.printf
      "Alertmanager accepted the synthetic alert.\n\n\
       This proves the route is configured and reachable. Confirm the named owner \
       received and acknowledged it: that delivered-and-acknowledged result is the \
       HARDEN-002 evidence, not this command's exit status.\n";
    Ok ()
  | Error (Invalid_target error) ->
    Error (Sol_cli_exit.failure (Sol_cli_config.error_to_string error))
  | Error (Invalid_delivery reason) ->
    Error
      (Sol_cli_exit.error
         ~code:2
         (Printf.sprintf
            "target %s does not satisfy the alert-delivery contract: %s"
            target
            reason))
  | Error (Rejected { exit_code; stderr }) ->
    Error
      (Sol_cli_exit.error
         (Printf.sprintf
            "Alertmanager rejected the synthetic alert (curl exit %d).\n\
             %s\n\
             Is the port-forward up? e.g. `kubectl -n monitoring port-forward \
             svc/prometheus-alertmanager 9093:9093`."
            exit_code
            stderr))
  | Error (Unreachable reason) ->
    Error (Sol_cli_exit.error ("could not run curl: " ^ reason))
;;

open Cmdliner

let target_arg =
  Sol_cli_target_arg.required_flag
    ~doc:
      "The production target whose alert route to exercise (e.g. `pilot/aws/us-east-1`). \
       Required: the target file is where the receiver/owner/runbook contract is \
       declared."
;;

let alertmanager_url_arg =
  Arg.(
    value
    & opt Sol_cli_args.text "http://127.0.0.1:9093"
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
    Term.(
      const (fun target url dry_run -> Sol_cli_exit.exit_on (run_test target url dry_run))
      $ target_arg
      $ alertmanager_url_arg
      $ dry_run_arg)
;;

let cmd =
  Cmd.group
    (Cmd.info "alert" ~doc:"Exercise the alert-to-owner response loop")
    [ test_cmd ]
;;
