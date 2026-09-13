open Cmdliner

(* FEAT-067: read the release records the cluster holds. Read-only — it never
   touches the deployment state, only lists what deploys recorded. *)

let workspace_name () = Filename.basename (Sys.getcwd ())

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
         "List the release records the target's cluster holds for this workspace, newest \
          first. Each row is a recorded deploy: id, commit, requested scope, time and \
          target. Records are written by 'sol up' and 'sol deploy'.")
    Term.(const (fun target -> run ~ctx:(Cmd_destination.top ~command:"releases" target) ()) $ Cmd_destination.required_target_arg)
;;
