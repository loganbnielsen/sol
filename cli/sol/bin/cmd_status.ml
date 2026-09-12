open Cmdliner

let workspace_name () =
  (match Sol_cli_workspace.find_root ~dir:(Sys.getcwd ()) with
   | Some root -> Sys.chdir root
   | None -> ());
  Filename.basename (Sys.getcwd ())
;;

let discover_domains () =
  let app_dir = "app" in
  if not (Sys.file_exists app_dir && Sys.is_directory app_dir)
  then []
  else (
    let domains = ref [] in
    (try
       Array.iter
         (fun entry ->
            let path = Filename.concat app_dir entry in
            if entry.[0] <> '.' && Sys.is_directory path then domains := entry :: !domains)
         (Sys.readdir app_dir)
     with
     | _ -> ());
    List.rev !domains)
;;

let namespace_or_exit ~workspace ~domain =
  match Sol_cli_deployment_plan.namespace_result ~workspace ~domain with
  | Ok namespace -> Sol_cli_deployment_plan.namespace_to_string namespace
  | Error err ->
    Printf.eprintf "error: %s\n" (Sol_cli_deployment_plan.plan_error_to_string err);
    exit 1
;;

(* Status projects a resolved selection into its own addressing model: the
   discovery list is passed down rather than re-read per domain, and [run] is
   what resolved the scope (through the same function every other command uses).
   Nothing here re-interprets a selector string. *)
let services_of_domain services domain =
  List.filter (fun (s : Sol_cli_manifest.service) -> s.domain = domain) services
;;

let service_diagnoses_named ~ns (services : Sol_cli_manifest.service list)
  : (string * string option) list
  =
  services
  |> List.filter_map (fun (s : Sol_cli_manifest.service) ->
    match Sol_cli_deployment_plan.k8s_name_result s.name with
    | Error _ -> None
    | Ok k8s_name ->
      let k8s_name = Sol_cli_deployment_plan.k8s_name_to_string k8s_name in
      let pod_expectation = Sol_cli_status.pod_expectation_of_primitive s.primitive in
      Some
        ( k8s_name
        , Sol_cli_rollout_diagnosis.diagnose_service_live
            ~pod_expectation
            ~ns
            ~service_name:s.name
            ~k8s_name
            () ))
;;

let service_diagnoses ~ns services = service_diagnoses_named ~ns services |> List.map snd

let ns_exists ns =
  match Sol_cli_kubectl.get_raw ~args:[ "get"; "ns"; ns ] with
  | Ok r -> r.Sol_cli_process.exit_code = 0
  | Error _ -> false
;;

(* The outer process-level timeout must give curl's own [--max-time] room
   to actually fire, write its [-w] output, and exit before the harness
   SIGKILLs it -- otherwise a borderline-slow connection races curl's own
   timeout handling and reports "timed out" instead of "connection failed".
   Same [timeout_s +. <buffer>] pattern as Sol_cli_loki.query. *)
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
  | Error e -> Error (Sol_cli_process.error_to_string e)
  | Ok r ->
    (match int_of_string_opt (String.trim r.Sol_cli_process.stdout) with
     | Some code -> Ok code
     | None -> Error "curl returned an unexpected response")
;;

(* Any 1xx-4xx response means *something* answered at this URL -- used for
   the dashboard link, a general Grafana base URL that may legitimately 3xx
   (e.g. to a login page) or 4xx (no default route at "/"); only "no
   response at all" (curl's "000") or a 5xx server error count as down. *)
let http_reachable url : (unit, string) result =
  match curl_status_code url ~timeout_s:2.0 with
  | Error e -> Error e
  | Ok code when code > 0 && code < 500 -> Ok ()
  | Ok 0 -> Error "connection failed"
  | Ok code -> Error (Printf.sprintf "HTTP %d" code)
;;

(* OBS-031: Loki's /ready and Prometheus's /-/healthy return 200
   specifically when genuinely up -- unlike the dashboard's generic
   base-URL probe above, a 4xx (wrong path, auth required) or 3xx here is a
   real problem to surface via unreachable_message, not "healthy". *)
let health_check_reachable url : (unit, string) result =
  match curl_status_code url ~timeout_s:2.0 with
  | Error e -> Error e
  | Ok code when code >= 200 && code < 300 -> Ok ()
  | Ok 0 -> Error "connection failed"
  | Ok code -> Error (Printf.sprintf "HTTP %d" code)
;;

(* ── Observability reachability ─────────────────────────────────────────── *)

let dashboard_reachability ~backend ~base_domain =
  match Sol_cli_observability_url.resolve ~backend ?base_domain () with
  | Sol_cli_observability_url.Url url ->
    Sol_cli_status.reachability_of_probe
      ~probe_url:(Some url)
      ~is_reachable:http_reachable
  | Sol_cli_observability_url.No_url _ -> Sol_cli_status.Not_checked
;;

(* OBS-031: prints the "not configured"/"unreachable" detail message
   in-line rather than the plain reachability word, so a self_hosted_durable/
   external target says why it isn't checking and what to pass instead of
   silently reading as the same "not checked" as everything else. The
   message selection itself ([Sol_cli_status.reachability_line]) is a pure
   function of [probe_url] and the injected [is_reachable] result -- only
   deciding the probe URL and running curl stays here. *)
let print_signal_line ~label ~signal ~backend ~explicit_url ~default_local_url ~probe_path
  =
  let probe_url =
    Sol_cli_status.probe_url ~backend ~explicit_url ~default_local_url ~probe_path
  in
  Printf.printf
    "  %-8s %s\n"
    label
    (Sol_cli_status.reachability_line
       ~signal
       ~backend
       ~probe_url
       ~is_reachable:health_check_reachable)
;;

let print_observability_lines ~backend ~explicit_loki_url ~explicit_prometheus_url =
  print_signal_line
    ~label:"logs"
    ~signal:Sol_cli_status.Loki
    ~backend
    ~explicit_url:explicit_loki_url
    ~default_local_url:"http://localhost:3100"
    ~probe_path:"/ready";
  print_signal_line
    ~label:"metrics"
    ~signal:Sol_cli_status.Prometheus
    ~backend
    ~explicit_url:explicit_prometheus_url
    ~default_local_url:"http://localhost:9090"
    ~probe_path:"/-/healthy";
  flush stdout
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
  Printf.printf "  metrics    sol open metrics%s\n" suffix;
  Printf.printf "  dashboard  sol open dashboard%s\n" suffix;
  (* Managed resource dashboards (OBS-044, e.g. RDS) are workspace-wide
     infrastructure, not domain/service-scoped -- only hinted at the
     workspace view, and as a generic command form (sol has no manifest of
     which managed resources are actually deployed to enumerate a real
     one here). *)
  if scope = ""
  then
    Printf.printf
      "  resource   sol open dashboard resource/<type>/<name>  (e.g. \
       resource/rds/<db-identifier>)\n";
  flush stdout
;;

(* ── Raw Kubernetes Diagnostics ─────────────────────────────────────────── *)

let print_raw_diagnostics ~ns ~domain ~services ~only_k8s_name =
  Printf.printf "\nNamespace: %s\n%!" ns;
  if ns_exists ns
  then (
    let pod_args =
      match only_k8s_name with
      | None -> [ "get"; "pods"; "-n"; ns ]
      | Some k8s_name -> [ "get"; "pods"; "-n"; ns; "-l"; "app=" ^ k8s_name ]
    in
    (match Sol_cli_kubectl.get_raw ~args:pod_args with
     | Ok r ->
       print_string r.Sol_cli_process.stdout;
       print_char '\n'
     | Error _ -> ());
    (* EXP-029: which image tag is actually live, without kubectl knowledge.
       Deployments rather than pods -- svc/worker are the only primitives
       with a live image tag worth confirming (Fn is a CronJob with no
       standing Deployment; this section is simply empty for it). *)
    let deploy_args =
      match only_k8s_name with
      | None -> [ "get"; "deployments"; "-n"; ns ]
      | Some k8s_name -> [ "get"; "deployments"; "-n"; ns; "-l"; "app=" ^ k8s_name ]
    in
    let image_jsonpath =
      "-o=jsonpath={range \
       .items[*]}{.metadata.name}{\"\\t\"}{.spec.template.spec.containers[0].image}{\"\\n\"}{end}"
    in
    (match Sol_cli_kubectl.get_raw ~args:(deploy_args @ [ image_jsonpath ]) with
     | Ok r
       when r.Sol_cli_process.exit_code = 0 && String.trim r.Sol_cli_process.stdout <> ""
       ->
       Printf.printf "Images\n";
       String.split_on_char '\n' (String.trim r.Sol_cli_process.stdout)
       |> List.iter (fun line ->
         match String.split_on_char '\t' line with
         | [ name; image ] -> Printf.printf "  %-20s %s\n" name image
         | _ -> ());
       print_char '\n'
     | _ -> ());
    service_diagnoses_named ~ns (services_of_domain services domain)
    |> List.iter (fun (k8s_name, diagnosis) ->
      match only_k8s_name with
      | Some only when only <> k8s_name -> ()
      | _ ->
        (match diagnosis with
         | None -> ()
         | Some d -> Printf.printf "%s\n%!" d));
    (* Port-forward hint for ClusterIP HTTP services in this namespace.
       Filter out internal services: names ending in "-headless" or equal
       to "kubernetes". *)
    let jsonpath = "{.items[?(@.spec.type==\"ClusterIP\")].metadata.name}" in
    let svc_names_raw =
      match
        Sol_cli_kubectl.get_raw
          ~args:[ "get"; "svc"; "-n"; ns; "-o"; "jsonpath=" ^ jsonpath ]
      with
      | Ok r when r.Sol_cli_process.exit_code = 0 -> r.Sol_cli_process.stdout
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
        List.filter
          (fun name ->
             (not (is_internal name))
             && (match only_k8s_name with
                 | Some only -> name = only
                 | None -> true)
             &&
             match
               Sol_cli_kubectl.get
                 ~resource:"svc"
                 ~name
                 ~namespace:ns
                 ~output:("jsonpath=" ^ port80_jsonpath)
             with
             | Ok r when r.Sol_cli_process.exit_code = 0 -> r.Sol_cli_process.stdout <> ""
             | _ -> false)
          names
      in
      List.iter
        (fun name -> Printf.printf "  →  http://localhost:8080  (%s)\n%!" name)
        http_svcs))
  else Printf.printf "  (not deployed — run 'sol up')\n%!";
  Printf.printf "\n%!"
;;

(* ── Workspace Scope ────────────────────────────────────────────────────── *)

let print_workspace_index
      ~workspace
      ~domains
      ~services
      ~backend
      ~explicit_loki_url
      ~explicit_prometheus_url
  =
  Printf.printf "\nDomains\n";
  List.iter
    (fun domain ->
       let ns = namespace_or_exit ~workspace ~domain in
       let exists = ns_exists ns in
       let diagnoses =
         if exists then service_diagnoses ~ns (services_of_domain services domain) else []
       in
       let status = Sol_cli_status.rollup_domain_status ~ns_exists:exists diagnoses in
       Printf.printf "  %-12s %s\n" domain (Sol_cli_status.domain_status_to_string status))
    domains;
  Printf.printf "\nObservability\n";
  Printf.printf "  backend  %s\n" (Sol_cli_observability_url.backend_to_string backend);
  print_observability_lines ~backend ~explicit_loki_url ~explicit_prometheus_url;
  print_open_block ~scope:""
;;

(* ── Domain Scope ───────────────────────────────────────────────────────── *)

let print_domain_status
      ~workspace
      ~domain
      ~services
      ~backend
      ~base_domain
      ~explicit_loki_url
      ~explicit_prometheus_url
  =
  let ns = namespace_or_exit ~workspace ~domain in
  let exists = ns_exists ns in
  let named =
    if exists
    then service_diagnoses_named ~ns (services_of_domain services domain)
    else []
  in
  let status =
    Sol_cli_status.rollup_domain_status ~ns_exists:exists (List.map snd named)
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
    List.iter
      (fun (k8s_name, diagnosis) ->
         let service_status =
           Sol_cli_status.rollup_domain_status ~ns_exists:true [ diagnosis ]
         in
         Printf.printf
           "  %-12s %s\n"
           k8s_name
           (Sol_cli_status.domain_status_to_string service_status))
      named;
  print_observability_block
    ~backend
    ~base_domain
    ~explicit_loki_url
    ~explicit_prometheus_url;
  print_open_block ~scope:domain;
  print_raw_diagnostics ~ns ~domain ~services ~only_k8s_name:None
;;

(* ── Service Scope ──────────────────────────────────────────────────────── *)

let print_service_status
      ~workspace
      ~domain
      ~service_name
      ~services
      ~backend
      ~base_domain
      ~explicit_loki_url
      ~explicit_prometheus_url
  =
  let ns = namespace_or_exit ~workspace ~domain in
  (* [services] is the resolver's selection for this scope: exactly the services
     whose canonical name matched [service_name]. *)
  let svc =
    match
      List.find_opt
        (fun (s : Sol_cli_manifest.service) ->
           s.domain = domain && Sol_cli_deployment_scope.equal_name s.name service_name)
        services
    with
    | Some svc -> svc
    | None ->
      Printf.eprintf "Service '%s' not found in domain '%s'.\n" service_name domain;
      exit 1
  in
  let k8s_name =
    match Sol_cli_deployment_plan.k8s_name_result svc.Sol_cli_manifest.name with
    | Ok k -> Sol_cli_deployment_plan.k8s_name_to_string k
    | Error err ->
      Printf.eprintf "error: %s\n" (Sol_cli_deployment_plan.plan_error_to_string err);
      exit 1
  in
  let pod_expectation =
    Sol_cli_status.pod_expectation_of_primitive svc.Sol_cli_manifest.primitive
  in
  let exists = ns_exists ns in
  let diagnosis =
    if exists
    then
      Sol_cli_rollout_diagnosis.diagnose_service_live
        ~pod_expectation
        ~ns
        ~service_name:k8s_name
        ~k8s_name
        ()
    else None
  in
  let status = Sol_cli_status.rollup_domain_status ~ns_exists:exists [ diagnosis ] in
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
  print_raw_diagnostics ~ns ~domain ~services ~only_k8s_name:(Some k8s_name)
;;

let run
      scope_str
      explicit_backend
      explicit_base_domain
      target
      explicit_loki_url
      explicit_prometheus_url
  =
  let workspace = workspace_name () in
  let all_domains = discover_domains () in
  if all_domains = []
  then (
    Printf.eprintf "No domains found in app/. Run from the workspace root.\n";
    exit 1);
  (* Discovery happens once; scope resolution then projects it into status's own
     addressing model (workspace / domain / unit / managed resource). *)
  let services = Sol_cli_manifest.discover_services () in
  let scope =
    match Sol_cli_open.parse_scope scope_str with
    | Ok s -> s
    | Error msg ->
      Printf.eprintf "error: %s\n" msg;
      exit 1
  in
  let resolve_status_scope request =
    match Sol_cli_workload_selection.resolve ~what:"status scope" request services with
    | Ok selected -> selected
    | Error message ->
      Printf.eprintf "error: %s\n" message;
      exit 1
  in
  let backend_and_base_domain () =
    match
      Sol_cli_observability_url.effective_backend_and_base_domain
        ~explicit_backend
        ~explicit_base_domain
        ~target
        ()
    with
    | Error msg ->
      Printf.eprintf "error: %s\n" msg;
      exit 1
    | Ok pair -> pair
  in
  match scope with
  | Sol_cli_open.Workspace ->
    let backend, _base_domain = backend_and_base_domain () in
    print_workspace_index
      ~workspace
      ~domains:all_domains
      ~services
      ~backend
      ~explicit_loki_url
      ~explicit_prometheus_url
  | Sol_cli_open.Resource (resource_type, resource_name) ->
    (* Managed resources (OBS-044, e.g. RDS) have no Kubernetes namespace to
       probe and sol has no AWS SDK dependency to query CloudWatch's own
       health directly (aws-eio is pinned into this switch but nothing in
       Sol consumes it yet) -- 'sol status resource/...' points at the
       dashboard rather than fabricating a health rollup it can't actually
       check. *)
    Printf.printf "\n%s/%s  (managed resource)\n" resource_type resource_name;
    Printf.printf "\nOpen\n";
    Printf.printf
      "  dashboard  sol open dashboard resource/%s/%s\n%!"
      resource_type
      resource_name
  | Sol_cli_open.Domain domain ->
    let selected = resolve_status_scope (Some domain) in
    let backend, base_domain = backend_and_base_domain () in
    print_domain_status
      ~workspace
      ~domain
      ~services:selected.Sol_cli_workload_selection.services
      ~backend
      ~base_domain
      ~explicit_loki_url
      ~explicit_prometheus_url
  | Sol_cli_open.Service (domain, service_name) ->
    let selected = resolve_status_scope (Some (domain ^ "/" ^ service_name)) in
    let backend, base_domain = backend_and_base_domain () in
    print_service_status
      ~workspace
      ~domain
      ~service_name
      ~services:selected.Sol_cli_workload_selection.services
      ~backend
      ~base_domain
      ~explicit_loki_url
      ~explicit_prometheus_url
;;

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let domain_arg =
  Arg.(
    value
    & pos 0 (some string) None
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
    & opt (some string) None
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
    & opt (some string) None
    & info
        [ "prometheus-base-url" ]
        ~docv:"URL"
        ~doc:
          "Base URL of the Prometheus instance to check for the Observability block's \
           reachability line. When omitted: checked at http://localhost:9090 for the \
           local backend; for any other backend, nothing is guessed and the line instead \
           explains why and prints the exact 'kubectl port-forward' command to run.")
;;

let backend_of_arg = function
  | None -> None
  | Some s ->
    (match Sol_cli_observability_url.backend_of_string s with
     | Some b -> Some b
     | None ->
       Printf.eprintf
         "error: unknown --observability-backend %S (expected: local, \
          self_hosted_durable, external)\n"
         s;
       exit 1)
;;

let cmd =
  Cmd.v
    (Cmd.info
       "status"
       ~doc:"Show workspace/domain/service health and observability status.")
    Term.(
      const
        (fun
            scope
             observability_backend
             base_domain
             target
             loki_base_url
             prometheus_base_url
           ->
           run
             scope
             (backend_of_arg observability_backend)
             base_domain
             target
             loki_base_url
             prometheus_base_url)
      $ domain_arg
      $ Cmd_logs.observability_backend_arg
      $ Cmd_logs.base_domain_arg
      $ Cmd_logs.target_arg
      $ loki_base_url_arg
      $ prometheus_base_url_arg)
;;
