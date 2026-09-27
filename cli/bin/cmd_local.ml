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

let pending_installs = ref []

let helm_install ~label release chart ~namespace ?version ?(values = []) ?values_yaml () =
  pending_installs
  := { Sol_cli_local_infra.label
     ; run =
         (fun () ->
           match
             upgrade_install ~release ~chart ~namespace ?version ~values ?values_yaml ()
           with
           | Ok _ -> Ok ()
           | Error (Sol_cli_process.Non_zero r) ->
             Error (Sol_cli_process.failure_message r)
           | Error e -> Error (Sol_cli_process.error_to_string e))
     }
     :: !pending_installs
;;

let run_local_infra_installs () =
  let installs = List.rev !pending_installs in
  pending_installs := [];
  Sol_cli_local_infra.run_bounded installs |> Sol_cli_exit.of_msg
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
      (Sol_cli_dev_observability.loki_datasource_configmap_yaml ~namespace:"monitoring")
  in
  let* () =
    if prometheus
    then
      apply_yaml
        (Sol_cli_dev_observability.prometheus_datasource_configmap_yaml
           ~namespace:"monitoring")
    else Ok ()
  in
  if tempo
  then
    apply_yaml
      (Sol_cli_dev_observability.tempo_datasource_configmap_yaml ~namespace:"monitoring")
  else Ok ()
;;

let declared_resources () =
  let* root =
    Sol_cli_workspace.resolve_validated ~dir:(Sys.getcwd ())
    |> Sol_cli_exit.of_error Sol_cli_workspace.workspace_error_to_string
  in
  Sol_cli_config.local_infra ~root |> Sol_cli_exit.of_error Sol_cli_config.error_to_string
;;

let deploy_infra ~(req : Sol_cli_workspace.infra_requirements) ~local =
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
        (Sol_cli_process.error_to_string e)));
  Sol_cli_local_platform.releases ~req ~assets:local
  |> List.iter (fun (r : Sol_cli_local_platform.release) ->
    helm_install
      ~label:r.label
      r.name
      r.chart
      ~namespace:r.namespace
      ?version:r.version
      ~values:r.values
      ?values_yaml:r.values_yaml
      ());
  let* () = run_local_infra_installs () in
  if Sol_cli_local_platform.needs_grafana req
  then
    install_local_grafana_config
      ~dashboards:local.dashboards
      ~prometheus:req.prometheus
      ~tempo:req.tempo
  else Ok ()
;;

let start_port_forwards ~(req : Sol_cli_workspace.infra_requirements) =
  Unix.sleepf 2.;
  Sol_cli_local_platform.endpoints ~req
  |> List.iter (fun { Sol_cli_local_platform.forward = pf; _ } ->
    Printf.printf
      "  port-forward  %-14s localhost:%d → %s/%s:%d\n%!"
      pf.name
      pf.local_port
      pf.namespace
      pf.target
      pf.remote_port;
    Sol_cli_port_forward.start ~ctx:Sol_cli_kube_destination.local_context pf
    |> Result.iter_error
         (Printf.eprintf "  warning: port-forward %s not started: %s\n%!" pf.name))
;;

let print_summary ~(req : Sol_cli_workspace.infra_requirements) =
  Printf.printf "\n";
  Printf.printf "  cluster      ✓  %s\n" Sol_cli_local_cluster.name;
  Printf.printf "  registry     ✓  localhost:%d\n" Sol_cli_local_cluster.registry_port;
  Sol_cli_local_platform.endpoints ~req
  |> List.iter (fun (e : Sol_cli_local_platform.endpoint) -> print_endline e.summary);
  Printf.printf "\n"
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
  Printf.printf "\n[4/4] Starting port-forwards...\n%!";
  start_port_forwards ~req;
  print_summary ~req;
  Ok ()
;;

let dev_down delete_cluster =
  let* () = check_tool "kubectl" "https://kubernetes.io/docs/tasks/tools/" in
  Printf.printf "Stopping port-forwards...\n%!";
  Sol_cli_port_forward.stop_all ();
  if delete_cluster
  then (
    let* () = check_tool "k3d" "https://k3d.io/" in
    Printf.printf "Deleting cluster %s...\n%!" Sol_cli_local_cluster.name;
    Sol_cli_local_cluster.delete ();
    Ok ())
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
       Sol_cli_process.run (Sol_cli_process.cmd [ "kubectl"; "get"; "pods"; "-A" ])
     with
     | Ok r ->
       print_string r.stdout;
       print_char '\n'
     | Error _ -> ());
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

type child =
  { pid : int
  ; label : string
  }

let dev_run workspace_dir scope =
  let dir =
    match workspace_dir with
    | Some d -> d
    | None -> "."
  in
  workspace_dir |> Option.iter Unix.chdir;
  let* facts = Sol_cli_workspace_model.load_cwd () |> Sol_cli_exit.of_msg in
  if not (String.equal (Sys.getcwd ()) facts.Sol_cli_workspace_model.root)
  then Unix.chdir facts.Sol_cli_workspace_model.root;
  let inventory = Sol_cli_workspace_model.services facts in
  let* { services; _ } =
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
  Printf.printf "\n%!";
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
  let children =
    plan.launches
    |> List.filter_map (fun (recipe : Sol_cli_local_run.recipe) ->
      let label = recipe.label in
      let cmd_str = Sol_cli_local_run.launch_line recipe.launch in
      let pipe_read, pipe_write = Unix.pipe () in
      let spawned =
        Sol_cli_process.spawn
          ~output:pipe_write
          (Sol_cli_process.cmd ~env:Sol_cli_local_run.dev_env [ "sh"; "-c"; cmd_str ])
      in
      Unix.close pipe_write;
      match spawned with
      | Ok child ->
        let _t = Thread.create (fun () -> prefix_lines_thread pipe_read label) () in
        Some { pid = Sol_cli_process.pid child; label }
      | Error e ->
        Unix.close pipe_read;
        Printf.eprintf
          "error: failed to spawn [%s]: %s\n"
          label
          (Sol_cli_process.error_to_string e);
        None)
  in
  let* children =
    match children with
    | [] -> Error (Sol_cli_exit.error "no services could be started")
    | children -> Ok children
  in
  Printf.printf "  Services running — press Ctrl-C to stop all.\n\n%!";
  let kill_all () =
    Printf.printf "\n  Stopping services...\n%!";
    children
    |> List.iter (fun c ->
      try Unix.kill c.pid Sys.sigterm with
      | _ -> ());
    Unix.sleepf 0.5;
    children
    |> List.iter (fun c ->
      try Unix.kill c.pid Sys.sigkill with
      | _ -> ())
  in
  Sys.set_signal
    Sys.sigint
    (Sys.Signal_handle
       (fun _ ->
         kill_all ();
         exit 130));
  let by_pid = Hashtbl.create 8 in
  List.iter (fun c -> Hashtbl.replace by_pid c.pid c) children;
  let remaining = ref (Hashtbl.length by_pid) in
  while !remaining > 0 do
    try
      let pid, status = Unix.wait () in
      decr remaining;
      match Hashtbl.find_opt by_pid pid with
      | None -> ()
      | Some c ->
        (match status with
         | Unix.WEXITED 0 -> ()
         | Unix.WEXITED n -> Printf.eprintf "[%s] exited with code %d\n%!" c.label n
         | Unix.WSIGNALED _ -> ()
         | Unix.WSTOPPED _ -> ())
    with
    | Unix.Unix_error _ -> remaining := 0
  done;
  Ok ()
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
    ; run_subcmd
    ]
;;
