open Cmdliner

(* FEAT-067: read the release records the cluster holds. Read-only — it never
   touches the deployment state, only lists what deploys recorded. *)

let workspace_name () = Filename.basename (Sys.getcwd ())

let run () =
  let workspace = workspace_name () in
  match Sol_cli_release_store.list ~workspace with
  | Error msg ->
    Printf.eprintf "error: %s\n" msg;
    exit 1
  | Ok [] ->
    Printf.printf
      "No releases recorded for workspace %s in the current cluster.\n"
      workspace
  | Ok records -> print_endline (Sol_cli_release.format_table records)
;;

let cmd =
  Cmd.v
    (Cmd.info
       "releases"
       ~doc:
         "List the release records the current cluster holds for this workspace, newest \
          first. Each row is a recorded deploy: id, commit, requested scope, time and \
          target. Records are written by 'sol up' and 'sol deploy'.")
    Term.(const run $ const ())
;;
