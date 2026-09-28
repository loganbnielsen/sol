open Cmdliner

let workspace_name = Sol_cli_workspace.current_name

open Result.Syntax

let render ~workspace = function
  | [] ->
    Printf.sprintf
      "No releases recorded for workspace %s in the target's cluster.\n"
      workspace
  | records -> Sol_cli_release.format_table records ^ "\n"
;;

let run ~ctx () =
  let workspace = workspace_name () in
  let* records = Sol_cli_release_store.list ~ctx ~workspace |> Sol_cli_exit.of_msg in
  print_string (render ~workspace records);
  Ok ()
;;

let cmd =
  Cmd.v
    (Cmd.info
       "releases"
       ~doc:
         "List the release records the target's cluster holds for this workspace. Each \
          row is a recorded release: its content-addressed id, the environment it \
          targets, and the number of workloads it contains. Records are written by 'sol \
          up' and 'sol deploy'.")
    Term.(
      const (fun target ->
        Sol_cli_exit.exit_on
          (let* ctx = Cmd_destination.remote ~command:"releases" target in
           run ~ctx ()))
      $ Cmd_destination.target_arg)
;;

let local_cmd =
  Cmd.v
    (Cmd.info
       "releases"
       ~doc:"List the release records Sol's local cluster holds for this workspace")
    Term.(
      const (fun () -> Sol_cli_exit.exit_on (run ~ctx:Cmd_destination.local ()))
      $ const ())
;;
