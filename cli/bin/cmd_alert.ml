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

let ( let* ) = Result.bind

(* What the send said, for the operator. Kept apart from sending it. *)
let report_outcome : Sol_cli_alert_test.outcome -> (unit, Sol_cli_exit.failure) result =
  function
  | Accepted ->
    Printf.printf
      "Alertmanager accepted the synthetic alert.\n\n\
       This proves the route is configured and reachable. Confirm the named owner \
       received and acknowledged it: that delivered-and-acknowledged result is the \
       HARDEN-002 evidence, not this command's exit status.\n";
    Ok ()
  | Rejected { exit_code; stderr } ->
    Error
      (Sol_cli_exit.error
         (Printf.sprintf
            "Alertmanager rejected the synthetic alert (curl exit %d).\n\
             %s\n\
             Is the port-forward up? e.g. `kubectl -n monitoring port-forward \
             svc/prometheus-alertmanager 9093:9093`."
            exit_code
            stderr))
  | Unreachable reason -> Error (Sol_cli_exit.error ("could not run curl: " ^ reason))
;;

let run_test target alertmanager_url dry_run =
  let* cfg =
    Sol_cli_config.load_for_target ~target
    |> Result.map_error (fun e -> Sol_cli_exit.failure (Sol_cli_config.error_to_string e))
  in
  let target_cfg = cfg.Sol_cli_config.target in
  let* () =
    Sol_cli_alerting.validate
      ~receiver_type:target_cfg.alert_receiver_type
      ~receiver_url:target_cfg.alert_receiver_url
      ~owner:target_cfg.alert_owner
      ~runbook_url:target_cfg.alert_runbook_url
    |> Result.map_error (fun reason ->
      Sol_cli_exit.error
        ~code:2
        (Printf.sprintf
           "target %s does not satisfy the alert-delivery contract: %s"
           target
           reason))
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
  then (
    Printf.printf "Would POST to %s:\n%s\n" url body;
    Printf.printf
      "\n\
       (dry run: nothing was sent; delivered-and-acknowledged evidence is HARDEN-002's)\n";
    Ok ())
  else (
    Printf.printf "Sending a synthetic alert through %s ...\n%!" url;
    Sol_cli_alert_test.send ~url ~body |> report_outcome)
;;

open Cmdliner

let target_arg =
  Arg.(
    required
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
