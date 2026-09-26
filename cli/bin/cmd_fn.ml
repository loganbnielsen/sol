(* sol fn run — manual invocation of a deployed -fn (FEAT-079).

   -fn is a run-once Kubernetes execution primitive; cron is one invocation
   mechanism, this is the other. The deployed CronJob's jobTemplate is the
   canonical execution definition (image, env, secrets, resources, retry
   policy) -- this command does not reconstruct or store a second copy of
   it from sol.toml/local source. It copies the live CronJob's template via
   `kubectl create job --from=cronjob/...`, so a manual run always executes
   exactly what the next scheduled tick would.

   Deliberately not constrained by the deployed CronJob's
   scheduled_concurrency: that field only governs overlap between the
   CronJob controller's own scheduled Jobs (Kubernetes' concurrencyPolicy
   semantics), never a manually created ad-hoc Job. Giving `sol fn run` a
   stronger guarantee than that would be dishonest about what
   scheduled_concurrency actually promises -- see FEAT-079's ticket. *)

open Cmdliner

(* REFAC-108: enter through the validated boundary, like every command. *)
let workspace_name () = Filename.basename (Sol_cli_workspace.enter_or_exit ())

(* Same resolution shape as `sol logs`'s resolve_unit: a selector must name
   exactly one workload. Here the selector is a required positional
   argument rather than --scope, and the resolved workload must additionally
   be a -fn -- `sol fn run` on a -svc/-worker name is a usage error, not a
   silent no-op. *)
let resolve_fn selector =
  let selected =
    match
      Sol_cli_workload_selection.resolve
        ~what:"DOMAIN/NAME"
        (Some selector)
        (Sol_cli_manifest.discover_services ())
    with
    | Ok selected -> selected
    | Error message ->
      Printf.eprintf "error: %s\n" message;
      exit 1
  in
  match selected.request, selected.services with
  | Sol_cli_deployment_scope.Unit_named _, [ svc ] ->
    (match svc.Sol_cli_manifest.primitive with
     | Fn -> svc
     | (Svc | Worker) as primitive ->
       Printf.eprintf
         "error: %s/%s is a %s, not a -fn; 'sol fn run' only invokes -fn workloads.\n"
         svc.Sol_cli_manifest.domain
         svc.Sol_cli_manifest.name
         (Sol_cli_manifest.primitive_label primitive);
       exit 1)
  | Sol_cli_deployment_scope.Unit_named _, _ ->
    Printf.eprintf "error: %S did not resolve to exactly one workload.\n" selector;
    exit 1
  | _ ->
    Printf.eprintf "error: 'sol fn run' addresses exactly one unit ('domain/name').\n";
    exit 1
;;

let namespace_or_exit ~workspace ~domain =
  match Sol_cli_deployment_plan.namespace_result ~workspace ~domain with
  | Ok namespace -> Sol_cli_deployment_plan.namespace_to_string namespace
  | Error err ->
    Printf.eprintf "error: %s\n" (Sol_cli_deployment_plan.plan_error_to_string err);
    exit 1
;;

let k8s_name_or_exit name =
  match Sol_cli_deployment_plan.k8s_name_result name with
  | Ok k8s_name -> Sol_cli_deployment_plan.k8s_name_to_string k8s_name
  | Error err ->
    Printf.eprintf "error: %s\n" (Sol_cli_deployment_plan.plan_error_to_string err);
    exit 1
;;

let run ~ctx selector =
  let workspace = workspace_name () in
  let svc = resolve_fn selector in
  let domain = svc.Sol_cli_manifest.domain in
  let name = svc.Sol_cli_manifest.name in
  let ns = namespace_or_exit ~workspace ~domain in
  let k8s_name = k8s_name_or_exit name in
  (match Sol_cli_kubectl.presence ~ctx ~args:[ "get"; "cronjob"; k8s_name; "-n"; ns ] with
   | Sol_cli_kubectl.Present -> ()
   | Sol_cli_kubectl.Absent _ ->
     Printf.eprintf "-fn %s/%s is not deployed in namespace %s.\n" domain name ns;
     Printf.eprintf "Run 'sol status' to see deployed services.\n";
     exit 1
   | Sol_cli_kubectl.Uncheckable why ->
     Printf.eprintf
       "error: could not check whether -fn %s/%s is deployed in namespace %s: %s\n"
       domain
       name
       ns
       why;
     exit 1);
  (* BUG-032: the name is minted in the lib rather than here, so the uniqueness
     rule is testable without a cluster — see Sol_cli_manual_job_name. The
     seconds-resolution form this replaced collided whenever two runs were fired in
     the same second, and the comment that justified it ("a manual run is a human
     typing a command") was the assumption that turned out to be false. *)
  let job_name = Sol_cli_manual_job_name.mint ~k8s_name in
  match
    Sol_cli_kubectl.create_job_from_cronjob ~ctx ~cronjob:k8s_name ~job_name ~namespace:ns
  with
  | Error e ->
    Printf.eprintf "error: %s\n" (Sol_cli_process.error_to_string e);
    exit 1
  | Ok r when r.Sol_cli_process.exit_code <> 0 ->
    Printf.eprintf "error: kubectl create job failed:\n%s\n" (String.trim r.stderr);
    exit 1
  | Ok _ ->
    Printf.printf
      "Created job %s from cronjob %s in namespace %s.\n%!"
      job_name
      k8s_name
      ns;
    Printf.printf "Track it with: sol logs %s/%s --target ...\n%!" domain name
;;

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let selector_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info
        []
        ~docv:"DOMAIN/NAME"
        ~doc:"The deployed -fn to invoke, e.g. billing/invoice_fn.")
;;

let run_cmd =
  Cmd.v
    (Cmd.info
       "run"
       ~doc:
         "Manually invoke a deployed -fn: creates one Kubernetes Job from the deployed \
          CronJob's jobTemplate (kubectl create job --from=cronjob/...), so a manual run \
          executes exactly what the next scheduled tick would. Not constrained by the \
          function's scheduled_concurrency -- that only governs overlap between the \
          CronJob controller's own scheduled runs, never a manual one.")
    Term.(
      const (fun selector target ->
        run
          ~ctx:
            (Cmd_destination.or_exit
               (Cmd_destination.resolve ~command:"fn run" ~local:false ~target))
          selector)
      $ selector_arg
      $ Cmd_destination.target_arg)
;;

let local_run_cmd =
  Cmd.v
    (Cmd.info "run" ~doc:"Manually invoke a deployed -fn on the local cluster.")
    Term.(const (fun selector -> run ~ctx:Cmd_destination.local selector) $ selector_arg)
;;

let cmd = Cmd.group (Cmd.info "fn" ~doc:"Operate on deployed -fn workloads.") [ run_cmd ]

let local_cmd =
  Cmd.group (Cmd.info "fn" ~doc:"Operate on -fn workloads.") [ local_run_cmd ]
;;
