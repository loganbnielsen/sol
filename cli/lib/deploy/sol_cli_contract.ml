let projection_dir ~workspace = Filename.concat workspace "contract"
let has_projection ~workspace = Sys.file_exists (projection_dir ~workspace)

type mode =
  | Check
  | Apply

let mode_arg = function
  | Check -> "--check"
  | Apply -> "--apply"
;;

let run ~workspace ~registry_url ~mode =
  if not (has_projection ~workspace)
  then Ok None
  else (
    let cmd =
      Sol_cli_process.cmd
        ~cwd:workspace
        ~env:[ "SCHEMA_REGISTRY_URL", registry_url ]
        ~timeout_s:300.
        [ "dune"; "exec"; "./contract/contract.exe"; "--"; mode_arg mode ]
    in
    match Sol_cli_process.run ~echo:true cmd with
    | Ok out -> Ok (Some out.stdout)
    | Error e -> Error (Sol_cli_process.error_to_string e))
;;

let report ~workspace ~registry_url ~mode =
  match run ~workspace ~registry_url ~mode with
  | Error msg -> Error msg
  | Ok None -> Ok ()
  | Ok (Some output) ->
    let trimmed = String.trim output in
    if trimmed <> "" then Sol_cli_report.app "%s" trimmed;
    Ok ()
;;
