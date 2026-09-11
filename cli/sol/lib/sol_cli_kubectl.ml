let run = Sol_cli_process.run
let run_ok = Sol_cli_process.run_ok
let cmd = Sol_cli_process.cmd
let apply ~file = run_ok (cmd [ "kubectl"; "apply"; "-f"; file ])

let apply_dry_run ~file =
  run_ok (cmd [ "kubectl"; "apply"; "-f"; file; "--dry-run=server" ])
;;

let get ~resource ~name ~namespace ~output =
  match run (cmd [ "kubectl"; "get"; resource; name; "-n"; namespace; "-o"; output ]) with
  | Ok r when r.Sol_cli_process.exit_code <> 0 ->
    Error (Sol_cli_process.Non_zero { exit_code = r.exit_code; stderr = r.stderr })
  | other -> other
;;

let get_raw ~args = run (cmd ([ "kubectl" ] @ args))

let logs ~pod ~namespace ~container =
  let container_args =
    match container with
    | None -> []
    | Some c -> [ "-c"; c ]
  in
  run (cmd ([ "kubectl"; "logs"; pod; "-n"; namespace ] @ container_args))
;;

let rollout_status ~kind_name ~namespace =
  run (cmd [ "kubectl"; "rollout"; "status"; kind_name; "-n"; namespace ])
;;

let rollout_undo ~kind_name ~namespace =
  run (cmd [ "kubectl"; "rollout"; "undo"; kind_name; "-n"; namespace ])
;;

let rollout_restart ~kind ~namespace =
  run (cmd [ "kubectl"; "rollout"; "restart"; kind; "-n"; namespace ])
;;

let patch ~resource ~name ~namespace ~patch_type ~patch =
  run
    (cmd
       [ "kubectl"
       ; "patch"
       ; resource
       ; name
       ; "-n"
       ; namespace
       ; "--type"
       ; patch_type
       ; "-p"
       ; patch
       ])
;;

let config_current_context () = run (cmd [ "kubectl"; "config"; "current-context" ])

let argo_rollout_undo ~namespace ~name =
  run ~echo:true (cmd [ "kubectl"; "argo"; "rollouts"; "undo"; name; "-n"; namespace ])
;;

let argo_rollout_status ~namespace ~name =
  run (cmd [ "kubectl"; "argo"; "rollouts"; "status"; name; "-n"; namespace ])
;;

(* A probe answers "is it reachable", and now also "and if not, what did kubectl
   say". The verdict is only half a diagnosis: the reason goes to stderr and used
   to be discarded here, which left `sol target show --check` able to report
   "unreachable" and nothing else (REFAC-084).

   Bounded on purpose: a probe is an inspection command, so it should not hang on
   a cluster that is simply unreachable. Sol's runner already spawns children with
   stdin on /dev/null (so a credential prompt returns EOF instead of waiting for
   input), and [timeout_s] bounds a network wait. *)
let probe_timeout_s = 15.0

(* Returns the exit code and the reason to show a human: stderr when kubectl
   wrote any, else stdout, trimmed. An [Error] means kubectl could not be run at
   all — distinct from running and failing. *)
let probe_result ~args =
  match run (cmd ~timeout_s:probe_timeout_s ([ "kubectl" ] @ args)) with
  | Error _ -> Error "kubectl could not be run"
  | Ok r ->
    let reason =
      let stderr = String.trim r.Sol_cli_process.stderr in
      if stderr <> "" then stderr else String.trim r.Sol_cli_process.stdout
    in
    Ok (r.Sol_cli_process.exit_code, reason)
;;

let probe ~args =
  match probe_result ~args with
  | Ok (0, _) -> true
  | Ok _ | Error _ -> false
;;
