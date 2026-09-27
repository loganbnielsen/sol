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

(* FRIC-017: k3d v5.6.0's embedded Docker client pins API 1.43, but Docker
   Engine 29 removed every API below 1.44, so any k3d invocation fails with
   "client version 1.43 is too old" on a current host. Ask the daemon for the
   oldest API it still accepts and hand that to k3d via DOCKER_API_VERSION --
   but never below k3d's own 1.43 floor, so older daemons keep working too. *)
let k3d_client_api_floor = "1.43"

let version_gt a b =
  let parts s = String.split_on_char '.' s |> List.filter_map int_of_string_opt in
  let rec cmp x y =
    match x, y with
    | [], [] -> 0
    | x :: xs, y :: ys -> if x <> y then compare x y else cmp xs ys
    | x :: _, [] -> compare x 0
    | [], y :: _ -> compare 0 y
  in
  cmp (parts a) (parts b) > 0
;;

let k3d_env () =
  match
    Sol_cli_process.run
      (Sol_cli_process.cmd
         [ "docker"; "version"; "--format"; "{{.Server.MinAPIVersion}}" ])
  with
  | Ok r ->
    let daemon_min = String.trim r.stdout in
    if daemon_min <> "" && version_gt daemon_min k3d_client_api_floor
    then [ "DOCKER_API_VERSION", daemon_min ]
    else []
  | _ -> []
;;

let k3d args = Sol_cli_process.cmd ~env:(k3d_env ()) ("k3d" :: args)

(* ── State file ─────────────────────────────────────────────────────────── *)

let cluster_name = "sol-local"
let registry_port = 5000

(* FEAT-042: host port the local ingress-nginx controller is port-forwarded
   to. Deliberately not 8080 -- that is where `sol up` forwards a service, so
   the two would collide. Nothing else in `sol local infra up` uses 8088. *)
let ingress_local_port = 8088

(* ── Helm helpers ────────────────────────────────────────────────────────── *)

(* FRIC-006: same discard-on-failure bug as the cluster-creation/docker/
   rollout sites this ticket already fixed -- upgrade_install's captured
   result/error was being collapsed to a bare exit code at all 7 call
   sites below, each printing only a generic "X install failed" with no
   indication of why (bad values, chart not found, timeout, etc). Centralized
   here instead of fixed at each site: every helm_install caller gets the
   real diagnostic for free. *)
(* INFRA-086: what this does with a failure has changed twice now, so both
   halves are worth stating. FRIC-006's diagnostic is preserved: the component's
   own output travels with the failure instead of a bare exit code. What is new
   is *when* it runs -- each call records its install and [run_local_infra_installs]
   below installs them with bounded concurrency, because the eight releases have
   no install-time dependency on each other and installing them one after another
   was ~290s of every golden path (both languages) and of a developer's first
   `sol local infra up`.

   Deferring also means the failure is no longer immediate: the component is
   reported once the in-flight installs have been waited for, together with the
   components that never got to run, and none of it can leave a half-installed
   sibling behind with no explanation. *)
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
  (* OBS-039: no longer auto-provisioned by a bundled loki-stack Grafana
     subchart -- see Sol_cli_dev_observability.loki_datasource_configmap_yaml.
     OBS-042: this datasource also carries the derivedFields link to Tempo,
     applied regardless of `tempo` -- harmless if Tempo isn't installed, and
     avoids two near-identical Loki datasource YAMLs. *)
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

(* ── dev up ──────────────────────────────────────────────────────────────── *)

(* Sol's local cluster, created unless it already exists. *)
let provision_cluster () =
  let cluster_exists =
    Result.is_ok (Sol_cli_process.run (k3d [ "cluster"; "get"; cluster_name ]))
  in
  if cluster_exists
  then (
    Printf.printf "  cluster %s already exists, skipping\n%!" cluster_name;
    Ok ())
  else (
    (* ponytail: FRIC-008, one-time Sun->Sol migration check -- delete this
       block once nobody plausibly still has a 'sun-local' cluster around.
       A pre-rename 'sun-local' cluster's inline registry binds the same
       host port this cluster's registry needs, causing a silent k3d
       port-bind conflict with no indication of the real cause. Blocks
       unconditionally on 'sun-local' existing at all (not just on a
       verified port-5000 conflict) -- deliberately simple for a shim
       meant to be deleted, not a permanent feature worth the extra
       port-probe logic to narrow. *)
    let pre_rename_cluster_name = "sun-local" in
    let pre_rename_cluster_exists =
      Result.is_ok
        (Sol_cli_process.run (k3d [ "cluster"; "get"; pre_rename_cluster_name ]))
    in
    let* () =
      if pre_rename_cluster_exists
      then
        Error
          (Sol_cli_exit.error
             (Printf.sprintf
                "found a pre-rename '%s' k3d cluster.\n\
                \  Sol's local cluster is now named '%s', and its registry would try\n\
                \  to bind the same host port (%d) that '%s'/'sun-registry' would also \
                 use.\n\
                \  Remove the old cluster first:\n\
                \    k3d cluster delete %s\n\
                \  (rename or keep it yourself first if you still need it for something \
                 else)"
                pre_rename_cluster_name
                cluster_name
                registry_port
                pre_rename_cluster_name
                pre_rename_cluster_name))
      else Ok ()
    in
    let create_result =
      Sol_cli_process.run
        ~echo:true
        (k3d
           [ "cluster"
           ; "create"
           ; cluster_name
           ; "--registry-create"
           ; Printf.sprintf "sol-registry:%d" registry_port
           ])
    in
    (* FRIC-006: k3d's own output is the actual diagnosis (e.g. "port is already
       allocated") -- surface it instead of leaving the user to re-run k3d by hand
       to find out why. *)
    create_result
    |> Result.map (fun _ -> ())
    |> Result.map_error (fun failure ->
      let detail =
        match failure with
        | Sol_cli_process.Non_zero r -> "\n" ^ Sol_cli_process.failure_message r
        | e -> "\n" ^ Sol_cli_process.error_to_string e
      in
      Sol_cli_exit.error ("cluster creation failed" ^ detail)))
;;

(* REFAC-107: what the workspace declares, read from sol.yml at the workspace
   root, not inferred from build files, so it is the same from any subdirectory
   and for OCaml and TypeScript units alike. *)
let declared_resources () =
  let* root =
    Sol_cli_workspace.resolve_validated ~dir:(Sys.getcwd ())
    |> Sol_cli_exit.of_error Sol_cli_workspace.workspace_error_to_string
  in
  Sol_cli_config.local_infra ~root |> Sol_cli_exit.of_error Sol_cli_config.error_to_string
;;

(* REFAC-139, part B: what to install is Sol_cli_local_platform's decision; this
   adds the repositories, queues each release and runs them. *)
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
  (* Grafana's datasource ConfigMaps name the services above, so they are applied
     once those releases exist -- after the installs, not interleaved with them. *)
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
  (* brief pause for service endpoints to settle *)
  let pf pf_spec =
    Printf.printf
      "  port-forward  %-14s localhost:%d → %s/%s:%d\n%!"
      pf_spec.Sol_cli_port_forward.name
      pf_spec.local_port
      pf_spec.namespace
      pf_spec.target
      pf_spec.remote_port;
    Sol_cli_port_forward.start ~ctx:Sol_cli_kube_destination.local_context pf_spec
    |> Result.iter_error
         (Printf.eprintf "  warning: port-forward %s not started: %s\n%!" pf_spec.name)
  in
  if req.kafka
  then (
    (* Target the pod, not svc: the headless service only exposes the internal
       port 9093, and the external listener on 9094 is pod-only. *)
    pf
      { name = "kafka"
      ; namespace = "redpanda"
      ; target = "pod/redpanda-0"
      ; local_port = 9092
      ; remote_port = 9094
      };
    pf
      { name = "schema-registry"
      ; namespace = "redpanda"
      ; target = "svc/redpanda"
      ; local_port = 8081
      ; remote_port = 8081
      });
  if req.postgres
  then
    pf
      { name = "postgres"
      ; namespace = "postgresql"
      ; target = "svc/postgresql"
      ; local_port = 5432
      ; remote_port = 5432
      };
  if Sol_cli_local_platform.needs_grafana req
  then
    pf
      { name = "loki"
      ; namespace = "monitoring"
      ; target = "svc/loki"
      ; local_port = 3100
      ; remote_port = 3100
      };
  if Sol_cli_local_platform.needs_grafana req
  then
    pf
      { name = "grafana"
      ; namespace = "monitoring"
      ; target = "svc/grafana"
      ; local_port = 3000
      ; remote_port = 80
      };
  if req.prometheus
  then
    pf
      { name = "prometheus"
      ; namespace = "monitoring"
      ; target = "svc/prometheus-server"
      ; local_port = 9090
      ; remote_port = 80
      };
  if req.prometheus
  then
    pf
      { name = "pushgateway"
      ; namespace = "monitoring"
      ; target = "svc/prometheus-prometheus-pushgateway"
      ; local_port = 9091
      ; remote_port = 9091
      };
  if req.tempo
  then (
    (* Two forwards, matching prometheus/pushgateway's split above: OTLP/HTTP
       ingestion (obs-tempo-eio's TEMPO_URL, what -svc pushes spans to) and
       the query API (what Grafana's Tempo datasource and a developer's own
       curl/Explore session read from) are different ports on the same
       Service. *)
    pf
      { name = "tempo"
      ; namespace = "monitoring"
      ; target = "svc/tempo"
      ; local_port = 4318
      ; remote_port = 4318
      };
    pf
      { name = "tempo-query"
      ; namespace = "monitoring"
      ; target = "svc/tempo"
      ; local_port = 3200
      ; remote_port = 3200
      });
  (* FEAT-042: the controller install above is unconditional, so is this
     forward -- a workspace Ingress can only be reached from the host through
     it. Remote port 80 is ingress-nginx's controller Service `http` port. *)
  pf
    { name = "ingress"
    ; namespace = "ingress-nginx"
    ; target = "svc/ingress-nginx-controller"
    ; local_port = ingress_local_port
    ; remote_port = 80
    }
;;

let print_summary ~(req : Sol_cli_workspace.infra_requirements) =
  Printf.printf "\n";
  Printf.printf "  cluster      ✓  %s\n" cluster_name;
  Printf.printf "  registry     ✓  localhost:%d\n" registry_port;
  if req.kafka then Printf.printf "  kafka        ✓  localhost:9092  (port-forwarded)\n";
  if req.kafka then Printf.printf "  schema-reg   ✓  http://localhost:8081\n";
  if req.postgres
  then
    Printf.printf
      "  postgres     ✓  postgresql://postgres:dev@localhost:5432/dev  (port-forwarded)\n";
  if Sol_cli_local_platform.needs_grafana req
  then Printf.printf "  loki         ✓  http://localhost:3100  (port-forwarded)\n";
  if Sol_cli_local_platform.needs_grafana req
  then Printf.printf "  grafana      ✓  http://localhost:3000  (port-forwarded)\n";
  if req.prometheus
  then Printf.printf "  prometheus   ✓  http://localhost:9090  (port-forwarded)\n";
  if req.prometheus
  then Printf.printf "  pushgateway  ✓  http://localhost:9091  (port-forwarded)\n";
  if req.tempo
  then Printf.printf "  tempo        ✓  http://localhost:4318  (OTLP, port-forwarded)\n";
  if req.tempo
  then Printf.printf "  tempo-query  ✓  http://localhost:3200  (port-forwarded)\n";
  Printf.printf
    "  ingress      ✓  http://localhost:%d  (ingress-nginx, port-forwarded)\n"
    ingress_local_port;
  Printf.printf "\n"
;;

let dev_up () =
  let* () = require_tools () in
  let* () = Sol_cli_state.ensure () |> Result.map_error Sol_cli_exit.error in
  (* Kill stale port-forwards from previous sessions, else re-running after a
     crash silently fails to bind ports while reporting success. *)
  Sol_cli_port_forward.stop_all ();
  Printf.printf "\n[1/4] Provisioning cluster...\n%!";
  let* () = provision_cluster () in
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

(* ── dev down ────────────────────────────────────────────────────────────── *)

let dev_down delete_cluster =
  let* () = check_tool "kubectl" "https://kubernetes.io/docs/tasks/tools/" in
  Printf.printf "Stopping port-forwards...\n%!";
  Sol_cli_port_forward.stop_all ();
  if delete_cluster
  then (
    let* () = check_tool "k3d" "https://k3d.io/" in
    Printf.printf "Deleting cluster %s...\n%!" cluster_name;
    ignore (Sol_cli_process.run (k3d [ "cluster"; "delete"; cluster_name ]));
    Ok ())
  else (
    Printf.printf "Port-forwards stopped. Cluster %s is still running.\n" cluster_name;
    Ok ())
;;

(* ── dev status ──────────────────────────────────────────────────────────── *)

let dev_status () =
  let* () = check_tool "kubectl" "https://kubernetes.io/docs/tasks/tools/" in
  let cluster_running =
    Result.is_ok (Sol_cli_process.run (k3d [ "cluster"; "get"; cluster_name ]))
  in
  Printf.printf
    "\nCluster:  %s  %s\n"
    cluster_name
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
    (* REFAC-126: what Sol recorded starting, and whether each is still up. *)
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

(* ── dev run ─────────────────────────────────────────────────────────────── *)

(** Dev-local addresses matching the port-forwards from [sol local infra up], mirroring
    the cluster-internal addresses [sol up] injects but rewritten to localhost.
*)
let dev_env_vars =
  [ "KAFKA_BROKERS", "localhost:9092"
  ; "SCHEMA_REGISTRY_URL", "http://localhost:8081"
  ; "REDPANDA_ADMIN_URL", "http://localhost:9644"
  ; "POSTGRES_URL", "postgresql://postgres:dev@localhost:5432/dev"
  ; "LOKI_URL", "http://localhost:3100"
  ; "PUSHGATEWAY_URL", "http://localhost:9091"
  ; "TEMPO_URL", "http://localhost:4318"
  ; "KAFKA_SECURITY_PROTOCOL", "plaintext"
  ]
;;

(** Read lines from [fd] and write them to stdout, prefixed with [label].
    Returns when EOF is reached (the child process closed the pipe end). *)
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
  (* Change to workspace dir if given explicitly so the workspace resolves *)
  workspace_dir |> Option.iter Unix.chdir;
  let* facts = Sol_cli_workspace_model.load_cwd () |> Sol_cli_exit.of_msg in
  (* The loop is workspace-root relative -- every path in the plan is -- and the
     workspace resolves from any descendant directory, so act from its root. *)
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
  (* FEAT-103: the declared language selects the adapter that builds and launches
     each unit, so the loop drives a TypeScript unit through npm and node exactly
     as it drives an OCaml one through dune. Every adapter is resolved before
     anything is built or started: a loop that quietly ran half a selection would
     be worse than one that refused. *)
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
  (* The OCaml units are one dune invocation (concurrent dune calls fight over
     the build lock); each TypeScript unit builds in its own npm project. *)
  let opam_eval = "eval $(opam env 2>/dev/null) 2>/dev/null; " in
  let* () =
    plan.builds
    |> List.fold_left
         (fun acc (build : Sol_cli_local_run.command) ->
            match acc with
            | Error _ as e -> e
            | Ok () ->
              let in_dir =
                match build.cwd with
                | "" | "." -> ""
                | cwd -> "cd " ^ Filename.quote cwd ^ " && "
              in
              let cmd =
                Printf.sprintf
                  "%s%s%s"
                  opam_eval
                  in_dir
                  (String.concat " " (List.map Filename.quote build.argv))
              in
              Sol_cli_process.run_shell cmd
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
  (* Run the built artifact directly, avoiding dune exec lock contention and
     keeping npm out of the supervised process: [sol local run] kills what it
     started, so it must start the service itself. *)
  let children =
    plan.launches
    |> List.filter_map (fun (recipe : Sol_cli_local_run.recipe) ->
      let label = recipe.label in
      let cmd_str =
        match recipe.launch.cwd with
        | "" | "." -> String.concat " " (List.map Filename.quote recipe.launch.argv)
        | cwd ->
          Printf.sprintf
            "cd %s && %s"
            (Filename.quote cwd)
            (String.concat " " (List.map Filename.quote recipe.launch.argv))
      in
      let pipe_read, pipe_write = Unix.pipe () in
      (* REFAC-134: spawned through Sol_cli_process, with the dev settings merged
         over the environment. *)
      let spawned =
        Sol_cli_process.spawn
          ~output:pipe_write
          (Sol_cli_process.cmd ~env:dev_env_vars [ "sh"; "-c"; cmd_str ])
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
  (* On SIGINT (Ctrl-C), kill every child before exiting *)
  let kill_all () =
    Printf.printf "\n  Stopping services...\n%!";
    children
    |> List.iter (fun c ->
      try Unix.kill c.pid Sys.sigterm with
      | _ -> ());
    (* Brief grace period, then SIGKILL *)
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
  (* Wait for children in any-exit order so an early crash is reported immediately *)
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

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

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

(* FEAT-063: `sol local` reads as "the local destination". The substrate
   lifecycle moves under `sol local infra`, so `sol local status` can mean the
   same thing as `sol status --target <t>` (workloads) rather than overloading
   "status" with two unrelated output domains. *)
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
