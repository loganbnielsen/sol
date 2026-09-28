open Cmdliner

let workspace_name = Sol_cli_workspace.current_name

open Result.Syntax

let run ~ctx () =
  let workspace = workspace_name () in
  let* records = Sol_cli_deployment_store.list ~ctx ~workspace |> Sol_cli_exit.of_msg in
  (match records with
   | [] ->
     Printf.printf
       "No deployments recorded for workspace %s in the target's cluster.\n"
       workspace
   | records -> print_endline (Sol_cli_deployment.format_table records));
  Ok ()
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
        let result =
          let* ctx = Cmd_destination.remote ~command:"deployments" target in
          run ~ctx ()
        in
        Sol_cli_exit.exit_on result)
      $ Cmd_destination.target_arg)
;;

let local_cmd =
  Cmd.v
    (Cmd.info
       "deployments"
       ~doc:"List the deployment events Sol's local cluster holds for this workspace")
    Term.(
      const (fun () -> Sol_cli_exit.exit_on (run ~ctx:Cmd_destination.local ()))
      $ const ())
;;
