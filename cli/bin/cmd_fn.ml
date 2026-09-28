open Cmdliner
open Result.Syntax

let resolve_fn ~facts selector =
  let* selected =
    Sol_cli_workload_selection.resolve
      ~what:"DOMAIN/NAME"
      (Some selector)
      (Sol_cli_workspace_model.services facts)
    |> Sol_cli_exit.of_msg
  in
  match selected.request, selected.services with
  | Sol_cli_deployment_scope.Unit_named _, [ ({ primitive = Fn; _ } as svc) ] -> Ok svc
  | Sol_cli_deployment_scope.Unit_named _, [ svc ] ->
    Error
      (Sol_cli_exit.error
         (Printf.sprintf
            "%s/%s is a %s, not a -fn; 'sol fn run' only invokes -fn workloads."
            svc.domain
            svc.name
            (Sol_cli_manifest.primitive_label svc.primitive)))
  | Sol_cli_deployment_scope.Unit_named _, _ ->
    Error
      (Sol_cli_exit.error
         (Printf.sprintf "%S did not resolve to exactly one workload." selector))
  | _ ->
    Error (Sol_cli_exit.error "'sol fn run' addresses exactly one unit ('domain/name').")
;;

let require_deployed ~ctx ~domain ~name ~ns ~k8s_name =
  match Sol_cli_kubectl.presence ~ctx ~args:[ "get"; "cronjob"; k8s_name; "-n"; ns ] with
  | Sol_cli_kubectl.Present -> Ok ()
  | Sol_cli_kubectl.Absent _ ->
    Error
      (Sol_cli_exit.failure
         (Printf.sprintf
            "-fn %s/%s is not deployed in namespace %s.\n\
             Run 'sol status' to see deployed services."
            domain
            name
            ns))
  | Sol_cli_kubectl.Uncheckable why ->
    Error
      (Sol_cli_exit.error
         (Printf.sprintf
            "could not check whether -fn %s/%s is deployed in namespace %s: %s"
            domain
            name
            ns
            why))
;;

let run ~ctx selector =
  let* { root; name = workspace } = Sol_cli_workspace.enter_cwd () in
  let* facts = Sol_cli_workspace_model.load ~root |> Sol_cli_exit.of_msg in
  let* svc = resolve_fn ~facts selector in
  let domain = svc.domain in
  let name = svc.name in
  let* ns =
    Sol_cli_deployment_plan.namespace_name ~workspace ~domain |> Sol_cli_exit.of_msg
  in
  let* k8s_name = Sol_cli_deployment_plan.k8s_name name |> Sol_cli_exit.of_msg in
  let* () = require_deployed ~ctx ~domain ~name ~ns ~k8s_name in
  let job_name = Sol_cli_manual_job_name.mint ~k8s_name in
  let* _ =
    Sol_cli_kubectl.create_job_from_cronjob ~ctx ~cronjob:k8s_name ~job_name ~namespace:ns
    |> Result.map_error (function
      | Sol_cli_process.Non_zero r ->
        Sol_cli_exit.error ("kubectl create job failed:\n" ^ String.trim r.stderr)
      | e -> Sol_cli_exit.error (Sol_cli_process.error_to_string e))
  in
  Printf.printf "Created job %s from cronjob %s in namespace %s.\n%!" job_name k8s_name ns;
  Printf.printf "Track it with: sol logs %s/%s --target ...\n%!" domain name;
  Ok ()
;;

let selector_arg =
  Arg.(
    required
    & pos 0 (some Sol_cli_args.text) None
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
        let result =
          let* ctx = Cmd_destination.remote ~command:"fn run" target in
          run ~ctx selector
        in
        Sol_cli_exit.exit_on result)
      $ selector_arg
      $ Cmd_destination.target_arg)
;;

let local_run_cmd =
  Cmd.v
    (Cmd.info "run" ~doc:"Manually invoke a deployed -fn on the local cluster.")
    Term.(
      const (fun selector ->
        Sol_cli_exit.exit_on (run ~ctx:Cmd_destination.local selector))
      $ selector_arg)
;;

let cmd = Cmd.group (Cmd.info "fn" ~doc:"Operate on deployed -fn workloads.") [ run_cmd ]

let local_cmd =
  Cmd.group (Cmd.info "fn" ~doc:"Operate on -fn workloads.") [ local_run_cmd ]
;;
