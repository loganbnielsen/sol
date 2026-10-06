open Cmdliner
open Result.Syntax

let discover_domains (facts : Sol_cli_workspace_model.t) =
  let workload_domains =
    List.map
      (fun (w : Sol_cli_workspace_model.workload) -> w.service.Sol_cli_manifest.domain)
      facts.Sol_cli_workspace_model.workloads
  in
  let unexpected_domains =
    List.map
      (fun ((domain, _, _) : Sol_cli_manifest.unexpected) -> domain)
      facts.Sol_cli_workspace_model.unexpected
  in
  let domains = workload_domains @ unexpected_domains in
  let seen = Hashtbl.create 16 in
  List.filter
    (fun domain ->
       if Hashtbl.mem seen domain
       then false
       else (
         Hashtbl.add seen domain ();
         true))
    domains
;;

let namespace ~workspace ~domain =
  Sol_cli_deployment_plan.namespace_name ~workspace ~domain |> Sol_cli_exit.of_msg
;;

let services_of_domain services domain =
  List.filter (fun (s : Sol_cli_manifest.service) -> s.domain = domain) services
;;

let service_diagnoses_named ~ctx ~ns (services : Sol_cli_manifest.service list)
  : (string * Sol_cli_rollout_diagnosis.diagnosis) list
  =
  services
  |> List.map (fun (s : Sol_cli_manifest.service) ->
    match Sol_cli_deployment_plan.k8s_name_result s.name with
    | Error e ->
      ( s.name
      , Sol_cli_rollout_diagnosis.Undetermined
          (Printf.sprintf
             "its Kubernetes name could not be resolved, so nothing was read: %s"
             (Sol_cli_deployment_plan.plan_error_to_string e)) )
    | Ok k8s_name ->
      let k8s_name = Sol_cli_deployment_plan.k8s_name_to_string k8s_name in
      let pod_expectation = Sol_cli_status.pod_expectation_of_primitive s.primitive in
      ( k8s_name
      , Sol_cli_rollout_diagnosis.diagnose_service_live
          ~ctx
          ~pod_expectation
          ~ns
          ~service_name:s.name
          ~k8s_name
          () ))
;;

let service_diagnoses ~ctx ~ns services =
  service_diagnoses_named ~ctx ~ns services |> List.map snd
;;

let namespace_presence ~ctx ns : Sol_cli_status.namespace_presence =
  match Sol_cli_kubectl.get_if_present ~ctx ~args:[ "get"; "ns"; ns ] with
  | Ok (Some _) -> Ns_present
  | Ok None -> Ns_absent
  | Error e -> Ns_unreadable (Sol_cli_process.error_to_string e)
;;

let curl_status_code url ~timeout_s : (int, string) result =
  match
    Sol_cli_process.run
      (Sol_cli_process.cmd
         ~timeout_s:(timeout_s +. 2.0)
         [ "curl"
         ; "-s"
         ; "-o"
         ; "/dev/null"
         ; "-w"
         ; "%{http_code}"
         ; "--max-time"
         ; string_of_float timeout_s
         ; url
         ])
  with
  | Ok { stdout; _ } | Error (Sol_cli_process.Non_zero { stdout; _ }) ->
    (match int_of_string_opt (String.trim stdout) with
     | Some code -> Ok code
     | None -> Error "curl returned an unexpected response")
  | Error e -> Error (Sol_cli_process.error_to_string e)
;;

let http_reachable url : (unit, string) result =
  let open Result.Syntax in
  let* code = curl_status_code url ~timeout_s:2.0 in
  match code with
  | code when code > 0 && code < 500 -> Ok ()
  | 0 -> Error "connection failed"
  | code -> Error (Printf.sprintf "HTTP %d" code)
;;

let health_check_reachable url : (unit, string) result =
  let open Result.Syntax in
  let* code = curl_status_code url ~timeout_s:2.0 in
  match code with
  | code when code >= 200 && code < 300 -> Ok ()
  | 0 -> Error "connection failed"
  | code -> Error (Printf.sprintf "HTTP %d" code)
;;

let dashboard_reachability ~backend ~base_domain =
  match Sol_cli_observability_url.resolve ~backend ?base_domain () with
  | Sol_cli_observability_url.Url url ->
    Sol_cli_status.reachability_of_probe
      ~probe_url:(Some url)
      ~is_reachable:http_reachable
  | Sol_cli_observability_url.No_url _ -> Sol_cli_status.Not_checked
;;

let signal_line ~signal ~backend ~explicit_url ~default_local_url ~probe_path =
  let probe_url =
    Sol_cli_status.probe_url ~backend ~explicit_url ~default_local_url ~probe_path
  in
  Sol_cli_status.reachability_line
    ~signal
    ~backend
    ~probe_url
    ~is_reachable:health_check_reachable
;;

let print_observability_lines ~backend ~explicit_loki_url ~explicit_prometheus_url =
  let logs =
    signal_line
      ~signal:Sol_cli_status.Loki
      ~backend
      ~explicit_url:explicit_loki_url
      ~default_local_url:(Sol_cli_manifest.local_url Sol_cli_manifest.loki_host_port)
      ~probe_path:"/ready"
  in
  let metrics =
    signal_line
      ~signal:Sol_cli_status.Prometheus
      ~backend
      ~explicit_url:explicit_prometheus_url
      ~default_local_url:
        (Sol_cli_manifest.local_url Sol_cli_manifest.prometheus_host_port)
      ~probe_path:"/-/healthy"
  in
  Printf.printf "  %-8s %s\n  %-8s %s\n%!" "logs" logs "metrics" metrics
;;

let print_observability_block
      ~backend
      ~base_domain
      ~explicit_loki_url
      ~explicit_prometheus_url
  =
  Printf.printf "\nObservability\n";
  print_observability_lines ~backend ~explicit_loki_url ~explicit_prometheus_url;
  Printf.printf
    "  dashboard  %s\n%!"
    (Sol_cli_status.reachability_to_string (dashboard_reachability ~backend ~base_domain))
;;

let print_open_block ~scope =
  let suffix =
    match scope with
    | "" -> ""
    | s -> " " ^ s
  in
  Printf.printf "\nOpen\n";
  Printf.printf "  logs       sol open logs%s\n" suffix;
  Printf.printf "  traces     sol open traces%s\n" suffix;
  Printf.printf "  metrics    sol open metrics%s\n" suffix;
  Printf.printf "  dashboard  sol open dashboard%s\n" suffix;
  if scope = ""
  then
    Printf.printf
      "  resource   sol open dashboard resource/<type>/<name>  (e.g. \
       resource/rds/<db-identifier>)\n";
  flush stdout
;;

let print_raw_diagnostics ~ctx ~ns ~domain ~services ~only_k8s_name =
  Printf.printf "\nNamespace: %s\n%!" ns;
  (match namespace_presence ~ctx ns with
   | Ns_unreadable why ->
     Printf.printf
       "  (namespace could not be read: %s)\n%!"
       (Sol_cli_status.first_line why)
   | Ns_present | Ns_absent -> ());
  if namespace_presence ~ctx ns = Ns_present
  then (
    let pod_args =
      match only_k8s_name with
      | None -> [ "get"; "pods"; "-n"; ns ]
      | Some k8s_name -> [ "get"; "pods"; "-n"; ns; "-l"; "app=" ^ k8s_name ]
    in
    (match Sol_cli_kubectl.get_raw ~ctx ~args:pod_args with
     | Ok r ->
       print_string r.stdout;
       print_char '\n'
     | Error _ -> ());
    let deploy_args =
      match only_k8s_name with
      | None -> [ "get"; "deployments"; "-n"; ns ]
      | Some k8s_name -> [ "get"; "deployments"; "-n"; ns; "-l"; "app=" ^ k8s_name ]
    in
    let image_jsonpath =
      "-o=jsonpath={range \
       .items[*]}{.metadata.name}{\"\\t\"}{.spec.template.spec.containers[0].image}{\"\\n\"}{end}"
    in
    (match Sol_cli_kubectl.get_raw ~ctx ~args:(deploy_args @ [ image_jsonpath ]) with
     | Ok r when String.trim r.stdout <> "" ->
       Printf.printf "Images\n";
       String.split_on_char '\n' (String.trim r.stdout)
       |> List.iter (fun line ->
         match String.split_on_char '\t' line with
         | [ name; image ] -> Printf.printf "  %-20s %s\n" name image
         | _ -> ());
       print_char '\n'
     | _ -> ());
    service_diagnoses_named ~ctx ~ns (services_of_domain services domain)
    |> List.iter (fun (k8s_name, diagnosis) ->
      match only_k8s_name with
      | Some only when only <> k8s_name -> ()
      | _ ->
        (match diagnosis with
         | Sol_cli_rollout_diagnosis.Unhealthy d -> Printf.printf "%s\n%!" d
         | Sol_cli_rollout_diagnosis.Undetermined why ->
           Printf.printf "diagnosis unavailable: %s\n%!" why
         | Sol_cli_rollout_diagnosis.Healthy -> ()));
    let jsonpath = "{.items[?(@.spec.type==\"ClusterIP\")].metadata.name}" in
    let svc_names_raw =
      match
        Sol_cli_kubectl.get_raw
          ~ctx
          ~args:[ "get"; "svc"; "-n"; ns; "-o"; "jsonpath=" ^ jsonpath ]
      with
      | Ok r -> r.stdout
      | _ -> ""
    in
    if svc_names_raw <> ""
    then (
      let names = String.split_on_char ' ' svc_names_raw in
      let is_internal name =
        name = "kubernetes"
        ||
        let n = String.length name in
        n >= 9 && String.sub name (n - 9) 9 = "-headless"
      in
      let port80_jsonpath = "{.spec.ports[?(@.port==80)].port}" in
      let http_svcs =
        names
        |> List.filter (fun name ->
          (not (is_internal name))
          && (match only_k8s_name with
              | Some only -> name = only
              | None -> true)
          &&
          match
            Sol_cli_kubectl.get
              ~ctx
              ~resource:"svc"
              ~name
              ~namespace:ns
              ~output:("jsonpath=" ^ port80_jsonpath)
          with
          | Ok r -> r.stdout <> ""
          | _ -> false)
      in
      http_svcs
      |> List.iter (fun name -> Printf.printf "  →  http://localhost:8080  (%s)\n%!" name)))
  else Printf.printf "  (not deployed — run 'sol up')\n%!";
  Printf.printf "\n%!"
;;

let print_workspace_index
      ~ctx
      ~workspace
      ~domains
      ~services
      ~backend
      ~explicit_loki_url
      ~explicit_prometheus_url
  =
  let* namespaces =
    domains
    |> Sol_cli_result.map_list (fun domain ->
      namespace ~workspace ~domain |> Result.map (fun ns -> domain, ns))
  in
  Printf.printf "\nDomains\n";
  namespaces
  |> List.iter (fun (domain, ns) ->
    let presence = namespace_presence ~ctx ns in
    let diagnoses =
      match presence with
      | Ns_present -> service_diagnoses ~ctx ~ns (services_of_domain services domain)
      | Ns_absent | Ns_unreadable _ -> []
    in
    let status = Sol_cli_status.rollup_domain_status ~ns_presence:presence diagnoses in
    Printf.printf "  %-12s %s\n" domain (Sol_cli_status.domain_status_to_string status));
  Printf.printf "\nObservability\n";
  Printf.printf "  backend  %s\n" (Sol_cli_observability_url.backend_to_string backend);
  print_observability_lines ~backend ~explicit_loki_url ~explicit_prometheus_url;
  print_open_block ~scope:"";
  Ok ()
;;

let print_domain_status
      ~ctx
      ~workspace
      ~domain
      ~services
      ~backend
      ~base_domain
      ~explicit_loki_url
      ~explicit_prometheus_url
  =
  let* ns = namespace ~workspace ~domain in
  let presence = namespace_presence ~ctx ns in
  let named =
    match presence with
    | Ns_present -> service_diagnoses_named ~ctx ~ns (services_of_domain services domain)
    | Ns_absent | Ns_unreadable _ -> []
  in
  let status =
    Sol_cli_status.rollup_domain_status ~ns_presence:presence (List.map snd named)
  in
  Printf.printf
    "\n%s  %s  %s\n"
    domain
    (Sol_cli_observability_url.backend_to_string backend)
    (Sol_cli_status.domain_status_to_string status);
  Printf.printf "\nServices\n";
  if named = []
  then Printf.printf "  (none)\n"
  else
    named
    |> List.iter (fun (k8s_name, diagnosis) ->
      let service_status =
        Sol_cli_status.rollup_domain_status ~ns_presence:Ns_present [ diagnosis ]
      in
      Printf.printf
        "  %-12s %s\n"
        k8s_name
        (Sol_cli_status.domain_status_to_string service_status));
  print_observability_block
    ~backend
    ~base_domain
    ~explicit_loki_url
    ~explicit_prometheus_url;
  print_open_block ~scope:domain;
  print_raw_diagnostics ~ctx ~ns ~domain ~services ~only_k8s_name:None;
  Ok ()
;;

let print_service_status
      ~ctx
      ~workspace
      ~domain
      ~service_name
      ~services
      ~backend
      ~base_domain
      ~explicit_loki_url
      ~explicit_prometheus_url
  =
  let* ns = namespace ~workspace ~domain in
  let* svc =
    services
    |> List.find_opt (fun (s : Sol_cli_manifest.service) ->
      s.domain = domain && Sol_cli_deployment_scope.equal_name s.name service_name)
    |> Option.to_result
         ~none:
           (Sol_cli_exit.failure
              (Printf.sprintf
                 "Service '%s' not found in domain '%s'."
                 service_name
                 domain))
  in
  let* k8s_name = Sol_cli_deployment_plan.k8s_name svc.name |> Sol_cli_exit.of_msg in
  let pod_expectation = Sol_cli_status.pod_expectation_of_primitive svc.primitive in
  let presence = namespace_presence ~ctx ns in
  let diagnoses =
    match presence with
    | Ns_present ->
      [ Sol_cli_rollout_diagnosis.diagnose_service_live
          ~ctx
          ~pod_expectation
          ~ns
          ~service_name:k8s_name
          ~k8s_name
          ()
      ]
    | Ns_absent | Ns_unreadable _ -> []
  in
  let status = Sol_cli_status.rollup_domain_status ~ns_presence:presence diagnoses in
  Printf.printf
    "\n%s/%s  %s\n"
    domain
    k8s_name
    (Sol_cli_status.domain_status_to_string status);
  print_observability_block
    ~backend
    ~base_domain
    ~explicit_loki_url
    ~explicit_prometheus_url;
  print_open_block ~scope:(domain ^ "/" ^ k8s_name);
  print_raw_diagnostics ~ctx ~ns ~domain ~services ~only_k8s_name:(Some k8s_name);
  Ok ()
;;

type status_options =
  { scope : string option
  ; target : string option
  ; observability : Cmd_logs.observability_options
  ; prometheus_base_url : string option
  }

let run ~ctx (options : status_options) =
  let scope_str = options.scope in
  let explicit_backend = options.observability.backend in
  let explicit_base_domain = options.observability.base_domain in
  let target = options.target in
  let explicit_loki_url = options.observability.loki_base_url in
  let explicit_prometheus_url = options.prometheus_base_url in
  let* { root; name = workspace } = Sol_cli_workspace.enter_cwd () in
  let* facts = Sol_cli_workspace_model.load ~root |> Sol_cli_exit.of_msg in
  let* all_domains =
    match discover_domains facts with
    | [] ->
      Error
        (Sol_cli_exit.failure "No domains found in app/. Run from the workspace root.")
    | domains -> Ok domains
  in
  let services = Sol_cli_workspace_model.services facts in
  let* scope = Sol_cli_open.parse_scope scope_str |> Sol_cli_exit.of_msg in
  let resolve_status_scope request =
    Sol_cli_workload_selection.resolve ~what:"status scope" request services
    |> Sol_cli_exit.of_msg
  in
  let backend_and_base_domain () =
    Sol_cli_observability_url.effective_backend_and_base_domain
      ~explicit_backend
      ~explicit_base_domain
      ~target
      ()
    |> Sol_cli_exit.of_msg
  in
  match scope with
  | Sol_cli_open.Workspace ->
    let* backend, _base_domain = backend_and_base_domain () in
    print_workspace_index
      ~ctx
      ~workspace
      ~domains:all_domains
      ~services
      ~backend
      ~explicit_loki_url
      ~explicit_prometheus_url
  | Sol_cli_open.Resource (resource_type, resource_name) ->
    Printf.printf "\n%s/%s  (managed resource)\n" resource_type resource_name;
    Printf.printf "\nOpen\n";
    Printf.printf
      "  dashboard  sol open dashboard resource/%s/%s\n%!"
      resource_type
      resource_name;
    Ok ()
  | Sol_cli_open.Domain domain ->
    let* selected = resolve_status_scope (Some domain) in
    let* backend, base_domain = backend_and_base_domain () in
    print_domain_status
      ~ctx
      ~workspace
      ~domain
      ~services:selected.services
      ~backend
      ~base_domain
      ~explicit_loki_url
      ~explicit_prometheus_url
  | Sol_cli_open.Service (domain, service_name) ->
    let* selected = resolve_status_scope (Some (domain ^ "/" ^ service_name)) in
    let* backend, base_domain = backend_and_base_domain () in
    print_service_status
      ~ctx
      ~workspace
      ~domain
      ~service_name
      ~services:selected.services
      ~backend
      ~base_domain
      ~explicit_loki_url
      ~explicit_prometheus_url
;;

let domain_arg =
  Arg.(
    value
    & pos 0 (some Sol_cli_args.text) None
    & info
        []
        ~docv:"SCOPE"
        ~doc:
          "Scope to show: omit for the workspace index, 'domain' for one domain's \
           services, or 'domain/service' for a single service.")
;;

let loki_base_url_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "loki-base-url" ]
        ~docv:"URL"
        ~doc:
          "Base URL of the Loki instance to check for the Observability block's \
           reachability line. When omitted: checked at http://localhost:3100 for the \
           local backend; for any other backend, nothing is guessed and the line instead \
           explains why and prints the exact 'kubectl port-forward' command to run.")
;;

let prometheus_base_url_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "prometheus-base-url" ]
        ~docv:"URL"
        ~doc:
          "Base URL of the Prometheus instance to check for the Observability block's \
           reachability line. When omitted: checked at http://localhost:9090 for the \
           local backend; for any other backend, nothing is guessed and the line instead \
           explains why and prints the exact 'kubectl port-forward' command to run.")
;;

let status_observability_term =
  Term.(
    const (fun backend base_domain loki_base_url ->
      { Cmd_logs.backend
      ; base_domain
      ; grafana_base_url = None
      ; loki_base_url
      ; loki_username = None
      ; loki_password = None
      })
    $ Cmd_logs.observability_backend_arg
    $ Cmd_logs.base_domain_arg
    $ loki_base_url_arg)
;;

let status_term ~local ~target_term =
  Term.(
    const (fun scope observability prometheus_base_url target ->
      let result =
        let* ctx =
          if local
          then Ok Cmd_destination.local
          else Cmd_destination.remote ~command:"status" target
        in
        run ~ctx { scope; target; observability; prometheus_base_url }
      in
      Sol_cli_exit.exit_on result)
    $ domain_arg
    $ status_observability_term
    $ prometheus_base_url_arg
    $ target_term)
;;

let cmd =
  Cmd.v
    (Cmd.info
       "status"
       ~doc:"Show workspace/domain/service health and observability status.")
    (status_term ~local:false ~target_term:Cmd_destination.target_arg)
;;

let local_cmd =
  Cmd.v
    (Cmd.info "status" ~doc:"Show local workload health and observability status")
    (status_term ~local:true ~target_term:(Term.const None))
;;
