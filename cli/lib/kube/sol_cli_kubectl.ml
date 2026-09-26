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
  Sol_cli_process.run_success
    (invocation ~ctx [ "get"; resource; name; "-n"; namespace; "-o"; output ])
;;

let get_raw ~ctx ~args = Sol_cli_process.run (invocation ~ctx args)

let resource_type_absent output =
  Sol_cli_string.contains ~needle:"doesn't have a resource type" output
  || Sol_cli_string.contains ~needle:"could not find the requested resource" output
;;

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

let rollout_status_with_timeout ~ctx ~kind_name ~namespace ~timeout_s =
  Sol_cli_process.run
    (invocation
       ~ctx
       [ "rollout"
       ; "status"
       ; kind_name
       ; "-n"
       ; namespace
       ; Printf.sprintf "--timeout=%ds" timeout_s
       ])
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
      Sol_cli_process.failure_output ~stdout:r.Sol_cli_process.stdout ~stderr:r.stderr
    in
    Ok (r.Sol_cli_process.exit_code, reason)
;;

(* A boolean probe cannot say the third thing: "kubectl could not be run" and
   "kubectl ran and said no" both collapse to `false`, and a caller that prints
   that as a fact about the cluster reports an absence it never established
   (FND-0024). [Present] and [Absent reason] are what kubectl answered; [reason]
   is what it said. [Uncheckable why] is that it could not be asked at all. The
   classifier is pure so the distinction is unit-testable without a cluster. *)
type presence =
  | Present
  | Absent of string
  | Uncheckable of string

let presence_of_probe_result = function
  | Ok (0, _) -> Present
  | Ok (code, reason) -> Absent (Printf.sprintf "kubectl exited %d: %s" code reason)
  | Error why -> Uncheckable why
;;

let presence ~ctx ~args = presence_of_probe_result (probe_result ~ctx ~args)
