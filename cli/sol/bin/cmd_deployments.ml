open Cmdliner

(* FEAT-070: read the deployment-event records the cluster holds. Read-only —
   it never touches the release store or reconstructs history from telemetry. *)

let workspace_name () = Filename.basename (Sys.getcwd ())

let run ~ctx () =
  let workspace = workspace_name () in
  match Sol_cli_deployment_store.list ~ctx ~workspace with
  | Error msg ->
    Printf.eprintf "error: %s\n" msg;
    exit 1
  | Ok [] ->
    Printf.printf
      "No deployments recorded for workspace %s in the target's cluster.\n"
      workspace
  | Ok records -> print_endline (Sol_cli_deployment.format_table records)
;;

let cmd =
  Cmd.v
    (Cmd.info
       "deployments"
       ~doc:
         "List the deployment events the target's cluster holds for this workspace, \
          newest first. Each row is one deploy invocation: its minted deployment id, the \
          release it attempted, when it ran, and the commit. Unlike 'sol releases' \
          (distinct released states), repeated no-op redeploys appear here as separate \
          events pointing at the same release.")
    Term.(
      const (fun target ->
        run
          ~ctx:
            (Cmd_destination.or_exit
               (Cmd_destination.resolve ~command:"deployments" ~local:false ~target))
          ())
      $ Cmd_destination.target_arg)
;;

(* FEAT-063: the local form -- deployment events from Sol's own cluster. *)
let local_cmd =
  Cmd.v
    (Cmd.info
       "deployments"
       ~doc:"List the deployment events Sol's local cluster holds for this workspace")
    Term.(const (fun () -> run ~ctx:Cmd_destination.local ()) $ const ())
;;
