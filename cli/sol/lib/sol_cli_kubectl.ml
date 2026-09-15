(* FEAT-063: every kubectl invocation is scoped to an explicit destination.

   The destination arrives as a [Sol_cli_kube_destination.context] and is applied
   here, once — [--context] plus, when one is scoped, [KUBECONFIG]. Nothing below
   reads the machine's ambient context, and no caller can inherit it by
   accident: the parameter is required, so a call site that forgets to say where
   it is talking to does not compile.

   This is a lib-level seam, so the destination stays a destination: it says
   *where* an operation reaches a cluster and never *what* is being deployed
   (FEAT-061 — scope travels on its own channel). *)

let invocation ?timeout_s ~ctx args =
  Sol_cli_process.cmd
    ~env:(Sol_cli_kube_destination.context_environment ctx)
    ?timeout_s
    ([ "kubectl" ] @ Sol_cli_kube_destination.kubectl_context_args ctx @ args)
;;

let apply ~ctx ~file = Sol_cli_process.run_ok (invocation ~ctx [ "apply"; "-f"; file ])

let apply_dry_run ~ctx ~file =
  Sol_cli_process.run_ok (invocation ~ctx [ "apply"; "-f"; file; "--dry-run=server" ])
;;

let get ~ctx ~resource ~name ~namespace ~output =
  match
    Sol_cli_process.run
      (invocation ~ctx [ "get"; resource; name; "-n"; namespace; "-o"; output ])
  with
  | Ok r when r.Sol_cli_process.exit_code <> 0 ->
    Error (Sol_cli_process.Non_zero { exit_code = r.exit_code; stderr = r.stderr })
  | other -> other
;;

let get_raw ~ctx ~args = Sol_cli_process.run (invocation ~ctx args)

let logs ~ctx ~pod ~namespace ~container =
  let container_args =
    match container with
    | None -> []
    | Some c -> [ "-c"; c ]
  in
  Sol_cli_process.run
    (invocation ~ctx ([ "logs"; pod; "-n"; namespace ] @ container_args))
;;

let rollout_status ~ctx ~kind_name ~namespace =
  Sol_cli_process.run
    (invocation ~ctx [ "rollout"; "status"; kind_name; "-n"; namespace ])
;;

let rollout_restart ~ctx ~kind ~namespace =
  Sol_cli_process.run (invocation ~ctx [ "rollout"; "restart"; kind; "-n"; namespace ])
;;

let patch ~ctx ~resource ~name ~namespace ~patch_type ~patch =
  Sol_cli_process.run
    (invocation
       ~ctx
       [ "patch"; resource; name; "-n"; namespace; "--type"; patch_type; "-p"; patch ])
;;

(* FEAT-072: [create] accepts the raw result rather than folding a non-zero exit
   into an error, because "AlreadyExists" is the atomic-acquire signal the
   boundary lease relies on and is not a failure of the call itself. *)
let create ~ctx ~file = Sol_cli_process.run (invocation ~ctx [ "create"; "-f"; file ])

(* FEAT-072: [replace] returns the raw result so a conflict is visible to the
   caller. Optimistic concurrency travels *in the object*: when [file] carries
   [metadata.resourceVersion], the API server rejects a stale write. There is
   deliberately no [--resource-version] flag — it is not present in every
   kubectl (the CI runner's does not have it). *)
let replace ~ctx ~file = Sol_cli_process.run (invocation ~ctx [ "replace"; "-f"; file ])

let create_job_from_cronjob ~ctx ~cronjob ~job_name ~namespace =
  Sol_cli_process.run
    (invocation
       ~ctx
       [ "create"; "job"; job_name; "--from=cronjob/" ^ cronjob; "-n"; namespace ])
;;

let delete ~ctx ~resource ~name ~namespace =
  Sol_cli_process.run_ok
    (invocation ~ctx [ "delete"; resource; name; "-n"; namespace; "--ignore-not-found" ])
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
let probe_result ~ctx ~args =
  match Sol_cli_process.run (invocation ~ctx ~timeout_s:probe_timeout_s args) with
  | Error _ -> Error "kubectl could not be run"
  | Ok r ->
    let reason =
      let stderr = String.trim r.Sol_cli_process.stderr in
      if stderr <> "" then stderr else String.trim r.Sol_cli_process.stdout
    in
    Ok (r.Sol_cli_process.exit_code, reason)
;;

let probe ~ctx ~args =
  match probe_result ~ctx ~args with
  | Ok (0, _) -> true
  | Ok _ | Error _ -> false
;;
