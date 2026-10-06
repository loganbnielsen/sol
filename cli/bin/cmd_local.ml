open Cmdliner
open Sol_cli_manifest
open Sol_cli_helm
open Result.Syntax

let check_tool name install_url =
  match Sol_cli_process.run (Sol_cli_process.cmd [ "which"; name ]) with
  | Ok _ -> Ok ()
  | Error _ ->
    Error
      (Sol_cli_exit.error
         (Printf.sprintf "%S not found in PATH.\n  Install: %s" name install_url))
;;

let require_tools () =
  let* () = check_tool "k3d" "https://k3d.io/" in
  let* () = check_tool "helm" "https://helm.sh/" in
  check_tool "kubectl" "https://kubernetes.io/docs/tasks/tools/"
;;

let helm_install_job (release : Sol_cli_local_platform.release)
  : Sol_cli_local_infra.install
  =
  { label = release.label
  ; run =
      (fun () ->
        upgrade_install
          ~ctx:Sol_cli_kube_destination.local_context
          ~release:release.name
          ~chart:release.chart
          ~namespace:release.namespace
          ?version:release.version
          ~values:release.values
          ?values_yaml:release.values_yaml
          ()
        |> Result.map ignore
        |> Result.map_error (function
          | Sol_cli_process.Non_zero r -> Sol_cli_process.failure_message r
          | e -> Sol_cli_process.error_to_string e))
  }
;;

let apply_yaml yaml =
  Sol_cli_fs.with_temp_file ~prefix:"sol-local-" ~suffix:".yaml" yaml (fun file ->
    Sol_cli_kubectl.apply ~ctx:Sol_cli_kube_destination.local_context ~file
    |> Result.map_error Sol_cli_process.error_to_string)
  |> Result.join
  |> Result.map_error (fun msg -> Sol_cli_exit.error ("kubectl apply failed: " ^ msg))
;;

let install_local_grafana_config ~dashboards ~prometheus ~tempo =
  let* () = apply_yaml dashboards in
  let* () =
    apply_yaml
      (Sol_cli_dev_observability.loki_datasource_configmap_yaml
         ~namespace:Sol_cli_manifest.monitoring_namespace)
  in
  let* () =
    if prometheus
    then
      apply_yaml
        (Sol_cli_dev_observability.prometheus_datasource_configmap_yaml
           ~namespace:Sol_cli_manifest.monitoring_namespace)
    else Ok ()
  in
  if tempo
  then
    apply_yaml
      (Sol_cli_dev_observability.tempo_datasource_configmap_yaml
         ~namespace:Sol_cli_manifest.monitoring_namespace)
  else Ok ()
;;

let declared_resources () =
  let* root =
    Sol_cli_workspace.resolve_validated ~dir:(Sys.getcwd ())
    |> Sol_cli_exit.of_error Sol_cli_workspace.workspace_error_to_string
  in
  Sol_cli_config.local_infra ~root |> Sol_cli_exit.of_error Sol_cli_config.error_to_string
;;

let prepare_helm_repositories_best_effort req =
  if Sol_cli_local_platform.needs_any_chart req
  then (
    Sol_cli_local_platform.repositories
    |> List.iter (fun (name, url) ->
      Sol_cli_helm.repo_add ~name ~url
      |> Result.iter_error (fun e ->
        Printf.eprintf
          "warning: helm repo add %s: %s\n%!"
          name
          (Sol_cli_process.error_to_string e)));
    Sol_cli_helm.repo_update ()
    |> Result.iter_error (fun e ->
      Printf.eprintf
        "warning: helm repo update: %s\n%!"
        (Sol_cli_process.error_to_string e)))
;;

let install_releases ~req ~local =
  Sol_cli_local_platform.releases ~req ~assets:local
  |> List.map helm_install_job
  |> Sol_cli_local_infra.run_bounded
  |> Sol_cli_exit.of_msg
;;

let deploy_infra ~(req : Sol_cli_workspace.infra_requirements) ~local =
  prepare_helm_repositories_best_effort req;
  let* () = install_releases ~req ~local in
  if Sol_cli_local_platform.needs_grafana req
  then
    install_local_grafana_config
      ~dashboards:local.dashboards
      ~prometheus:req.prometheus
      ~tempo:req.tempo
  else Ok ()
;;

let endpoint_start (e : Sol_cli_local_platform.endpoint) : Sol_cli_local_infra.endpoint =
  { Sol_cli_local_infra.endpoint_label = e.forward.name
  ; endpoint_required = e.required
  ; endpoint_start =
      (fun () ->
        Printf.printf
          "  port-forward  %-14s localhost:%d → %s/%s:%d (waiting for readiness)\n%!"
          e.forward.name
          e.forward.local_port
          e.forward.namespace
          e.forward.target
          e.forward.remote_port;
        Sol_cli_port_forward.ensure_ready
          ~ctx:Sol_cli_kube_destination.local_context
          e.forward
        |> Result.map_error Sol_cli_port_forward.readiness_error_to_string)
  ; endpoint_stop = (fun () -> Sol_cli_port_forward.stop e.forward.name)
  }
;;

let print_endpoint_summary endpoints outcomes =
  Printf.printf "\n";
  Printf.printf "  cluster      ✓  %s\n" Sol_cli_local_cluster.name;
  Printf.printf "  registry     ✓  localhost:%d\n" Sol_cli_local_cluster.registry_port;
  List.iter2
    (fun (e : Sol_cli_local_platform.endpoint) outcome ->
       match outcome with
       | Sol_cli_local_infra.Ready -> print_endline e.summary
       | Sol_cli_local_infra.Optional_unavailable message ->
         Printf.printf "  %-14s –  optional; not available (%s)\n" e.forward.name message)
    endpoints
    outcomes;
  Printf.printf "\n"
;;

let start_port_forwards ~(req : Sol_cli_workspace.infra_requirements) =
  let endpoints = Sol_cli_local_platform.endpoints ~req in
  let* outcomes =
    endpoints
    |> List.map endpoint_start
    |> Sol_cli_local_infra.bring_up_endpoints
    |> Sol_cli_exit.of_msg
  in
  print_endpoint_summary endpoints outcomes;
  Ok ()
;;

let dev_up () =
  let* () = require_tools () in
  let* () = Sol_cli_state.ensure () |> Result.map_error Sol_cli_exit.error in
  Sol_cli_port_forward.stop_all ();
  Printf.printf "\n[1/4] Provisioning cluster...\n%!";
  let* () = Sol_cli_local_cluster.provision () |> Result.map_error Sol_cli_exit.error in
  Printf.printf "\n[2/4] Reading the workspace's declared resources...\n%!";
  let* req = declared_resources () in
  Printf.printf
    "  kafka=%-5b  postgres=%-5b  loki=%-5b  prometheus=%-5b  tempo=%b\n%!"
    req.kafka
    req.postgres
    req.loki
    req.prometheus
    req.tempo;
  let* local = Sol_cli_local_platform.read_assets () |> Sol_cli_exit.of_msg in
  Printf.printf "\n[3/4] Deploying infra...\n%!";
  let* () = deploy_infra ~req ~local in
  Printf.printf "\n[4/4] Starting and verifying port-forwards...\n%!";
  start_port_forwards ~req
;;

let dev_down delete_cluster =
  let* () = check_tool "kubectl" "https://kubernetes.io/docs/tasks/tools/" in
  Printf.printf "Stopping port-forwards...\n%!";
  Sol_cli_port_forward.stop_all ();
  if delete_cluster
  then (
    let* () = check_tool "k3d" "https://k3d.io/" in
    Printf.printf "Deleting cluster %s...\n%!" Sol_cli_local_cluster.name;
    let* () = Sol_cli_local_cluster.delete () |> Sol_cli_exit.of_msg in
    Sol_cli_local_cluster.confirm_removed () |> Sol_cli_exit.of_msg)
  else (
    Printf.printf
      "Port-forwards stopped. Cluster %s is still running.\n"
      Sol_cli_local_cluster.name;
    Ok ())
;;

let dev_status () =
  let* () = check_tool "kubectl" "https://kubernetes.io/docs/tasks/tools/" in
  let cluster_running = Sol_cli_local_cluster.exists () in
  Printf.printf
    "\nCluster:  %s  %s\n"
    Sol_cli_local_cluster.name
    (if cluster_running then "✓ running" else "✗ not found");
  if cluster_running
  then (
    Printf.printf "\nPods:\n%!";
    (match
       Sol_cli_kubectl.get_raw
         ~ctx:Sol_cli_kube_destination.local_context
         ~args:[ "get"; "pods"; "-A" ]
     with
     | Ok r ->
       print_string r.stdout;
       print_char '\n'
     | Error e ->
       Printf.printf "  could not read pods: %s\n" (Sol_cli_process.error_to_string e));
    Printf.printf "\nPort-forwards:\n%!";
    let recorded, unreadable = Sol_cli_port_forward.records () in
    (match recorded with
     | [] -> Printf.printf "  none\n"
     | recorded ->
       recorded
       |> List.iter (fun (pf : Sol_cli_port_forward.spec) ->
         Printf.printf
           "  %-12s  localhost:%d → %s/%s  %s\n"
           pf.name
           pf.local_port
           pf.namespace
           pf.target
           (if Sol_cli_port_forward.is_running pf.name then "running" else "stopped")));
    unreadable
    |> List.iter (Printf.eprintf "  warning: unreadable port-forward record: %s\n"));
  Printf.printf "\n";
  Ok ()
;;

let prefix_lines_thread fd label =
  let ic = Unix.in_channel_of_descr fd in
  (try
     while true do
       let line = input_line ic in
       Printf.printf "[%s] %s\n%!" label line
     done
   with
   | End_of_file | Sys_error _ -> ());
  try Unix.close fd with
  | _ -> ()
;;

let resolve_run workspace_dir scope =
  workspace_dir |> Option.iter Unix.chdir;
  let* facts = Sol_cli_workspace_model.load_cwd () |> Sol_cli_exit.of_msg in
  if not (String.equal (Sys.getcwd ()) facts.Sol_cli_workspace_model.root)
  then Unix.chdir facts.Sol_cli_workspace_model.root;
  let inventory = Sol_cli_workspace_model.services facts in
  let* { requested_scope; services; _ } =
    Sol_cli_workload_selection.resolve_nonempty
      ~none:
        "no Sol services found. Expected app/<domain>/<name>_{svc,worker,fn}/ \
         directories with a Dockerfile."
      scope
      inventory
    |> Sol_cli_exit.of_msg
  in
  let* plan =
    Sol_cli_local_run.plan ~root:facts.Sol_cli_workspace_model.root ~facts services
    |> function
    | Ok plan -> Ok plan
    | Error errors ->
      errors
      |> List.iter (fun (label, message) ->
        Printf.eprintf "error: %s %s\n%!" label message);
      Error (Sol_cli_exit.reported ())
  in
  let* () =
    Sol_cli_contract.report
      ~workspace:facts.Sol_cli_workspace_model.root
      ~registry_url:Sol_cli_local_run.dev_registry_url
      ~scope:requested_scope
      ~mode:Sol_cli_contract.Apply
    |> Sol_cli_exit.of_msg
  in
  Ok (services, plan)
;;

let report_run_start ~dir ~services (plan : Sol_cli_local_run.plan) =
  Printf.printf "\n  Starting %d service(s) from %s\n" (List.length services) dir;
  plan.launches
  |> List.iter (fun (recipe : Sol_cli_local_run.recipe) ->
    let svc =
      List.find
        (fun svc -> String.equal (Sol_cli_local_run.label svc) recipe.label)
        services
    in
    Printf.printf
      "    [%s] %s → %s\n"
      (primitive_label svc.primitive)
      recipe.label
      recipe.artifact);
  Printf.printf "\n%!"
;;

let build_services (plan : Sol_cli_local_run.plan) =
  Printf.printf "  Building...\n%!";
  let* () =
    plan.builds
    |> List.fold_left
         (fun acc (build : Sol_cli_local_run.command) ->
            match acc with
            | Error _ as e -> e
            | Ok () ->
              Sol_cli_process.run_shell (Sol_cli_local_run.build_line build)
              |> Result.map ignore
              |> Result.map_error (fun e ->
                Sol_cli_exit.error
                  (Printf.sprintf
                     "%s failed: %s"
                     (String.concat " " build.argv)
                     (Sol_cli_process.error_to_string e))))
         (Ok ())
  in
  Printf.printf "  Build done.\n\n%!";
  Ok ()
;;

let launch_services (plan : Sol_cli_local_run.plan) =
  Sol_cli_local_run.launch_all
    ~output:(fun (recipe : Sol_cli_local_run.recipe) ->
      let pipe_read, pipe_write = Unix.pipe ~cloexec:true () in
      let _t = Thread.create (fun () -> prefix_lines_thread pipe_read recipe.label) () in
      pipe_write)
    plan.launches
  |> Result.map_error Sol_cli_local_run.child_failure_to_string
  |> Sol_cli_exit.of_msg
;;

let supervise_children children =
  Printf.printf "  Services running — press Ctrl-C to stop all.\n\n%!";
  let on_status (child : Sol_cli_local_run.child) status =
    match status with
    | Unix.WEXITED 0 -> ()
    | Unix.WEXITED code ->
      Printf.eprintf "[%s] exited with code %d\n%!" child.child_label code
    | Unix.WSIGNALED signal ->
      Printf.eprintf "[%s] was signalled (%d)\n%!" child.child_label signal
    | Unix.WSTOPPED signal ->
      Printf.eprintf "[%s] was stopped (%d)\n%!" child.child_label signal
  in
  match Sol_cli_local_run.supervise ~on_status children with
  | Ok () -> Ok ()
  | Error (Sol_cli_local_run.Interrupted signal) ->
    Printf.printf "\n  Stopping services...\n%!";
    Error (Sol_cli_exit.reported ~code:(Sol_cli_local_run.interrupt_exit_code signal) ())
  | Error failure ->
    Error (Sol_cli_exit.error (Sol_cli_local_run.child_failure_to_string failure))
;;

let dev_run workspace_dir scope =
  let dir = Option.value workspace_dir ~default:"." in
  let* services, plan = resolve_run workspace_dir scope in
  report_run_start ~dir ~services plan;
  let* () = build_services plan in
  let* children = launch_services plan in
  supervise_children children
;;

let up_cmd =
  Cmd.v
    (Cmd.info
       "up"
       ~doc:"Provision local k3d cluster and deploy all required infra via Helm")
    Term.(const Sol_cli_exit.exit_on $ (const dev_up $ const ()))
;;

let down_cmd =
  let cluster_flag =
    Arg.(value & flag & info [ "cluster" ] ~doc:"Also delete the k3d cluster")
  in
  Cmd.v
    (Cmd.info "down" ~doc:"Stop port-forwards (and optionally delete the cluster)")
    Term.(const Sol_cli_exit.exit_on $ (const dev_down $ cluster_flag))
;;

let status_cmd =
  Cmd.v
    (Cmd.info "status" ~doc:"Show infra pod health and registered port-forwards")
    Term.(const Sol_cli_exit.exit_on $ (const dev_status $ const ()))
;;

let run_workspace_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "workspace"; "C" ]
        ~docv:"DIR"
        ~doc:"Workspace root directory (default: current directory)")
;;

let run_scope_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "scope" ]
        ~docv:"DOMAIN[/UNIT]"
        ~doc:
          "Run one domain (`payments`) or one unit (`payments/charge_svc`). Omit to run \
           every service in the workspace.")
;;

let run_subcmd =
  Cmd.v
    (Cmd.info
       "run"
       ~doc:"Start all workspace services locally using dune exec with dev env vars")
    Term.(
      const Sol_cli_exit.exit_on $ (const dev_run $ run_workspace_arg $ run_scope_arg))
;;

let infra_cmd =
  Cmd.group
    (Cmd.info
       "infra"
       ~doc:"Manage the local Kubernetes substrate (k3d, Redpanda, Postgres, Grafana)")
    [ up_cmd; down_cmd; status_cmd ]
;;

let cmd =
  Cmd.group
    (Cmd.info "local" ~doc:"Operate on Sol's own local cluster (k3d)")
    [ infra_cmd
    ; Cmd_status.local_cmd
    ; Cmd_logs.local_cmd
    ; Cmd_fn.local_cmd
    ; Cmd_rollback.local_cmd
    ; Cmd_migrate.local_cmd
    ; Cmd_releases.local_cmd
    ; Cmd_deployments.local_cmd
    ; Cmd_secret.local_cmd
    ; run_subcmd
    ]
;;
