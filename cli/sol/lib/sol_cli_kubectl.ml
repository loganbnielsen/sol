let run = Sol_cli_process.run
let run_ok = Sol_cli_process.run_ok
let cmd = Sol_cli_process.cmd
let apply ~file = run_ok (cmd [ "kubectl"; "apply"; "-f"; file ])

let apply_dry_run ~file =
  run_ok (cmd [ "kubectl"; "apply"; "-f"; file; "--dry-run=server" ])

let get ~resource ~name ~namespace ~output =
  match
    run
      (cmd [ "kubectl"; "get"; resource; name; "-n"; namespace; "-o"; output ])
  with
  | Ok r when r.Sol_cli_process.exit_code <> 0 ->
      Error
        (Sol_cli_process.Non_zero { exit_code = r.exit_code; stderr = r.stderr })
  | other -> other

let get_raw ~args = run (cmd ([ "kubectl" ] @ args))

let logs ~pod ~namespace ~container =
  let container_args =
    match container with None -> [] | Some c -> [ "-c"; c ]
  in
  run (cmd ([ "kubectl"; "logs"; pod; "-n"; namespace ] @ container_args))

let rollout_status ~kind_name ~namespace =
  run (cmd [ "kubectl"; "rollout"; "status"; kind_name; "-n"; namespace ])

let rollout_undo ~kind_name ~namespace =
  run (cmd [ "kubectl"; "rollout"; "undo"; kind_name; "-n"; namespace ])

let rollout_restart ~kind ~namespace =
  run (cmd [ "kubectl"; "rollout"; "restart"; kind; "-n"; namespace ])

let patch ~resource ~name ~namespace ~patch_type ~patch =
  run
    (cmd
       [
         "kubectl";
         "patch";
         resource;
         name;
         "-n";
         namespace;
         "--type";
         patch_type;
         "-p";
         patch;
       ])

let config_current_context () =
  run (cmd [ "kubectl"; "config"; "current-context" ])

let argo_rollout_undo ~namespace ~name =
  run ~echo:true
    (cmd [ "kubectl"; "argo"; "rollouts"; "undo"; name; "-n"; namespace ])

let argo_rollout_status ~namespace ~name =
  run (cmd [ "kubectl"; "argo"; "rollouts"; "status"; name; "-n"; namespace ])

let probe ~args =
  match run (cmd ([ "kubectl" ] @ args)) with
  | Ok r -> r.Sol_cli_process.exit_code = 0
  | Error _ -> false
