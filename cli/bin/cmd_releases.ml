open Cmdliner

(* FEAT-067: read the release records the cluster holds. Read-only — it never
   touches the deployment state, only lists what deploys recorded. *)

(* DEC-024: the workspace name comes from the resolved root, so it is the same
   from any descendant directory. *)
let workspace_name = Sol_cli_workspace.current_name

let run ~ctx () =
  let workspace = workspace_name () in
  match Sol_cli_release_store.list ~ctx ~workspace with
  | Error msg ->
    Printf.eprintf "error: %s\n" msg;
    exit 1
  | Ok [] ->
    Printf.printf
      "No releases recorded for workspace %s in the target's cluster.\n"
      workspace
  | Ok records -> print_endline (Sol_cli_release.format_table records)
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
        run
          ~ctx:
            (Cmd_destination.or_exit
               (Cmd_destination.resolve ~command:"releases" ~local:false ~target))
          ())
      $ Cmd_destination.target_arg)
;;

(* FEAT-063: the local form -- release records from Sol's own cluster. *)
let local_cmd =
  Cmd.v
    (Cmd.info
       "releases"
       ~doc:"List the release records Sol's local cluster holds for this workspace")
    Term.(const (fun () -> run ~ctx:Cmd_destination.local ()) $ const ())
;;
