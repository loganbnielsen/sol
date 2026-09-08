type rollback_target =
  | Standard_deployment of { namespace: string; name: string }
  | Argo_rollout        of { namespace: string; name: string }
  | No_op               of string

type error =
  | Kubectl_error   of Sol_cli_process.error
  | Plugin_missing  of { namespace: string; name: string }
  | Non_zero        of { command: string; exit_code: int }

let rollback_target_of_service (s : Sol_cli_deployment_plan.service_spec) =
  let ns   = Sol_cli_deployment_plan.namespace_to_string s.namespace in
  let name = Sol_cli_deployment_plan.k8s_name_to_string s.k8s_name in
  match s.primitive with
  | Sol_cli_deployment_plan.Fn ->
    No_op "function workloads are managed by CronJob — no rollout history"
  | Sol_cli_deployment_plan.Svc
  | Sol_cli_deployment_plan.Worker ->
    (match s.progressive_delivery with
     | Some _ -> Argo_rollout        { namespace = ns; name }
     | None   -> Standard_deployment { namespace = ns; name })

let argo_plugin_available () =
  (match Sol_cli_process.run
           (Sol_cli_process.cmd ["kubectl-argo-rollouts"; "version"]) with
   | Ok r -> r.Sol_cli_process.exit_code = 0
   | Error _ -> false)
  || Sol_cli_kubectl.probe ~args:["argo"; "rollouts"; "version"]

let execute_rollback target =
  match target with
  | No_op _ -> Ok ()

  | Standard_deployment { namespace; name } ->
    let kind_name = "deployment/" ^ name in
    (match Sol_cli_kubectl.rollout_undo ~kind_name ~namespace with
     | Error e -> Error (Kubectl_error e)
     | Ok r when r.Sol_cli_process.exit_code <> 0 ->
       Error (Non_zero { command = "kubectl rollout undo"; exit_code = r.Sol_cli_process.exit_code })
     | Ok _ ->
       (match Sol_cli_kubectl.rollout_status ~kind_name ~namespace with
        | Error e -> Error (Kubectl_error e)
        | Ok r when r.Sol_cli_process.exit_code <> 0 ->
          Error (Non_zero { command = "kubectl rollout status"; exit_code = r.Sol_cli_process.exit_code })
        | Ok _ -> Ok ()))

  | Argo_rollout { namespace; name } ->
    if not (argo_plugin_available ()) then
      Error (Plugin_missing { namespace; name })
    else
      (match Sol_cli_kubectl.argo_rollout_undo ~namespace ~name with
       | Error e -> Error (Kubectl_error e)
       | Ok r when r.Sol_cli_process.exit_code <> 0 ->
         Error (Non_zero { command = "kubectl argo rollouts undo";
                           exit_code = r.Sol_cli_process.exit_code })
       | Ok _ ->
         (match Sol_cli_kubectl.argo_rollout_status ~namespace ~name with
          | Error e -> Error (Kubectl_error e)
          | Ok r when r.Sol_cli_process.exit_code <> 0 ->
            Error (Non_zero { command = "kubectl argo rollouts status";
                              exit_code = r.Sol_cli_process.exit_code })
          | Ok _ -> Ok ()))

let error_to_string = function
  | Kubectl_error e ->
    "kubectl error: " ^ Sol_cli_process.error_to_string e
  | Plugin_missing { namespace; name } ->
    Printf.sprintf
      "service %s/%s uses Argo Rollouts — install the Argo Rollouts kubectl plugin to roll back.\n\
      \    Install: https://argoproj.github.io/argo-rollouts/installation/#kubectl-plugin\n\
      \    Manual:  kubectl argo rollouts undo %s -n %s"
      namespace name name namespace
  | Non_zero { command; exit_code } ->
    Printf.sprintf "%s exited with code %d" command exit_code
