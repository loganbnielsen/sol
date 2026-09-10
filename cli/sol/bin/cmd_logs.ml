open Cmdliner

let workspace_name () =
  (match Sol_cli_workspace.find_root ~dir:(Sys.getcwd ()) with
   | Some root -> Sys.chdir root
   | None -> ());
  Filename.basename (Sys.getcwd ())
;;

let find_service_by_name name =
  let app_dir = "app" in
  if not (Sys.file_exists app_dir && Sys.is_directory app_dir)
  then []
  else (
    let matches = ref [] in
    (try
       Array.iter
         (fun domain ->
            let domain_path = Filename.concat app_dir domain in
            if domain.[0] <> '.' && Sys.is_directory domain_path
            then (
              try
                Array.iter
                  (fun svc ->
                     if svc.[0] <> '.'
                     then (
                       let svc_path = Filename.concat domain_path svc in
                       if Sys.is_directory svc_path && svc = name
                       then matches := (domain, svc) :: !matches))
                  (Sys.readdir domain_path)
              with
              | _ -> ()))
         (Sys.readdir app_dir)
     with
     | _ -> ());
    List.rev !matches)
;;

let resolve_service arg =
  if String.contains arg '/'
  then (
    match String.split_on_char '/' arg with
    | [ domain; name ] -> Some (domain, name)
    | _ ->
      Printf.eprintf "error: service path must be in 'domain/name' form, got '%s'.\n" arg;
      exit 1)
  else (
    match find_service_by_name arg with
    | [] ->
      Printf.eprintf "error: service '%s' not found in app/.\n" arg;
      Printf.eprintf "  Use 'domain/name' form or run from the workspace root.\n";
      exit 1
    | [ (domain, name) ] -> Some (domain, name)
    | matches ->
      Printf.eprintf "error: '%s' is ambiguous — found in multiple domains:\n" arg;
      List.iter (fun (d, n) -> Printf.eprintf "  %s/%s\n" d n) matches;
      Printf.eprintf
        "  Specify the full path, e.g. 'sol logs %s/%s'.\n"
        (fst (List.hd matches))
        arg;
      exit 1)
;;

let declared_service ~domain ~k8s_name =
  Sol_cli_manifest.discover_services ~filter_path:None
  |> List.find_opt (fun (s : Sol_cli_manifest.service) ->
    s.domain = domain
    &&
    match Sol_cli_deployment_plan.k8s_name_result s.name with
    | Ok name -> Sol_cli_deployment_plan.k8s_name_to_string name = k8s_name
    | Error _ -> false)
;;

let workload_exists ~ns ~primitive ~k8s_name =
  let kind =
    match (primitive : Sol_cli_manifest.primitive) with
    | Fn -> "cronjob"
    | Svc | Worker -> "deployment"
  in
  match
    Sol_cli_process.run
      (Sol_cli_process.cmd [ "kubectl"; "get"; kind; k8s_name; "-n"; ns ])
  with
  | Ok r -> r.Sol_cli_process.exit_code = 0
  | Error _ -> false
;;

let namespace_or_exit ~workspace ~domain =
  match Sol_cli_deployment_plan.namespace_result ~workspace ~domain with
  | Ok namespace -> Sol_cli_deployment_plan.namespace_to_string namespace
  | Error err ->
    Printf.eprintf "error: %s\n" (Sol_cli_deployment_plan.plan_error_to_string err);
    exit 1
;;

let kubectl_log_target ~primitive ~k8s_name : Sol_cli_logs.kubectl_log_target =
  match (primitive : Sol_cli_manifest.primitive) with
  | Fn -> App_selector k8s_name
  | Svc | Worker -> Deployment k8s_name
;;

let exec_kubectl_logs ~ns ~target ~follow ~tail =
  let argv = Sol_cli_logs.kubectl_logs_argv ~ns ~target ~follow ~tail in
  Unix.execvp "kubectl" (Array.of_list argv)
;;

let run
      ~service_arg
      ~follow
      ~tail
      ~explicit_backend
      ~explicit_base_domain
      ~target
      ~explicit_loki_url
      ~explicit_loki_username
      ~explicit_loki_password
      ?grafana_base_url
      ()
  : unit
  =
  let workspace = workspace_name () in
  let domain, name =
    match resolve_service service_arg with
    | Some p -> p
    | None -> exit 1
  in
  let ns = namespace_or_exit ~workspace ~domain in
  let k8s_name =
    match Sol_cli_deployment_plan.k8s_name_result name with
    | Ok k8s_name -> Sol_cli_deployment_plan.k8s_name_to_string k8s_name
    | Error err ->
      Printf.eprintf "error: %s\n" (Sol_cli_deployment_plan.plan_error_to_string err);
      exit 1
  in
  let primitive =
    match declared_service ~domain ~k8s_name with
    | Some service -> service.Sol_cli_manifest.primitive
    | None ->
      Printf.eprintf "Service '%s' not found in domain '%s'.\n" name domain;
      exit 1
  in
  let backend, base_domain =
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
  (match
     Sol_cli_observability_url.resolve ~backend ?base_domain ?override:grafana_base_url ()
   with
   | Sol_cli_observability_url.Url base_url ->
     let url = Sol_cli_logs.grafana_explore_url ~base_url ~ns ~k8s_name in
     Printf.printf "Grafana logs: %s\n%!" url
   | Sol_cli_observability_url.No_url reason ->
     Printf.printf "Grafana logs: (%s)\n%!" reason);
  let kubectl_target = kubectl_log_target ~primitive ~k8s_name in
  let fallback_to_kubectl () =
    if not (workload_exists ~ns ~primitive ~k8s_name)
    then (
      Printf.eprintf "Service %s not found in namespace %s.\n" name ns;
      Printf.eprintf "Run 'sol status' to see deployed services.\n";
      exit 1);
    (match
       Sol_cli_rollout_diagnosis.diagnose_service_live
         ~pod_expectation:(Sol_cli_status.pod_expectation_of_primitive primitive)
         ~ns
         ~service_name:name
         ~k8s_name
         ()
     with
     | Some diagnosis -> Printf.printf "%s\n%!" diagnosis
     | None -> ());
    exec_kubectl_logs ~ns ~target:kubectl_target ~follow ~tail
  in
  if follow
  then fallback_to_kubectl ()
  else (
    match
      Sol_cli_status.probe_url
        ~backend
        ~explicit_url:explicit_loki_url
        ~default_local_url:"http://localhost:3100"
        ~probe_path:""
    with
    | None ->
      (* OBS-031: no --loki-base-url and backend isn't Local -- nothing to
         guess at, distinct from the query-failed case below. *)
      Printf.printf
        "(%s. Showing Kubernetes logs.)\n%!"
        (Sol_cli_status.not_configured_message ~signal:Sol_cli_status.Loki ~backend);
      fallback_to_kubectl ()
    | Some loki_base_url ->
      let credentials =
        match
          Sol_cli_loki.resolve_credentials
            ~flag_username:explicit_loki_username
            ~flag_password:explicit_loki_password
            ~env_username:(Sys.getenv_opt "SOL_LOKI_USERNAME")
            ~env_password:(Sys.getenv_opt "SOL_LOKI_PASSWORD")
        with
        | Ok credentials -> credentials
        | Error msg ->
          Printf.eprintf "error: %s\n" msg;
          exit 1
      in
      (match
         Sol_cli_loki.query
           ~base_url:loki_base_url
           ~ns
           ~k8s_name
           ?credentials
           ~limit:tail
           ()
       with
       | Ok [] ->
         Printf.printf
           "(no log lines found in Loki for %s; showing Kubernetes logs)\n%!"
           name;
         fallback_to_kubectl ()
       | Ok lines -> List.iter (fun (l : Sol_cli_loki.line) -> print_endline l.text) lines
       | Error e ->
         (* OBS-031: a URL was configured and the request itself failed
           (connection refused, timeout, non-2xx) -- a real outage or a
           wrong URL, not the "nothing to check" case above. *)
         Printf.printf
           "(%s. Falling back to Kubernetes logs for %s...)\n%!"
           (Sol_cli_status.unreachable_message
              ~url:loki_base_url
              ~error:(Sol_cli_loki.fetch_error_to_string e))
           name;
         fallback_to_kubectl ()))
;;

(* ── Cmdliner Terms ─────────────────────────────────────────────────────── *)

let service_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info
        []
        ~docv:"SERVICE"
        ~doc:
          "Service to stream logs from, in 'domain/name' or bare 'name' form (e.g. \
           payments/charge_svc or charge_svc). Underscores are accepted; Sol maps them \
           to hyphens in Kubernetes.")
;;

let follow_flag =
  Arg.(
    value
    & flag
    & info
        [ "follow"; "f" ]
        ~doc:
          "Stream logs in real time. This is the default; pass --no-follow for a \
           snapshot.")
;;

let no_follow_flag =
  Arg.(
    value
    & flag
    & info [ "no-follow" ] ~doc:"Print a log snapshot and exit without streaming.")
;;

let tail_arg =
  Arg.(
    value
    & opt int 100
    & info
        [ "tail" ]
        ~docv:"N"
        ~doc:
          "Number of recent lines to show before following (default: 100). Pass 0 to \
           skip history and stream only new lines.")
;;

let grafana_base_url_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "grafana-base-url" ]
        ~docv:"URL"
        ~doc:
          "Override the Grafana base URL instead of resolving it from \
           --observability-backend. Sol prints a copyable Grafana Explore URL with a \
           LogQL query before streaming kubectl logs.")
;;

let observability_backend_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "observability-backend" ]
        ~docv:"BACKEND"
        ~doc:
          "Which observability_backend (see cli/platform/infra/base) this target uses: \
           local, self_hosted_durable, or external. Overrides whatever --target's config \
           supplies; defaults to local when neither is given. Determines the Grafana URL \
           Sol resolves when --grafana-base-url is not given.")
;;

let base_domain_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "base-domain" ]
        ~docv:"DOMAIN"
        ~doc:
          "Base domain for the self_hosted_durable backend's Grafana Ingress \
           (grafana.<base-domain>). Overrides whatever --target's config supplies. \
           Required for that backend unless --grafana-base-url overrides it directly.")
;;

let target_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "target" ]
        ~docv:"ENV/PROVIDER/REGION"
        ~doc:
          "Deployment target path (same as sol plan/sol cloud tf, e.g. \
           prod/aws/us-east-1). When given, its sol.yml config supplies the \
           observability_backend/base_domain defaults instead of the hardcoded local \
           default.")
;;

let loki_base_url_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "loki-base-url" ]
        ~docv:"URL"
        ~doc:
          "Base URL of the Loki instance. When omitted: checked at http://localhost:3100 \
           for the local backend, otherwise Loki is skipped and 'sol logs' goes straight \
           to 'kubectl logs' rather than guessing. 'sol logs' queries Loki first for a \
           snapshot (--no-follow) and falls back to 'kubectl logs' if the query fails, \
           times out, or finds nothing.")
;;

let loki_username_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "loki-username" ]
        ~docv:"USERNAME"
        ~doc:
          "Basic-auth username for the Loki query request (e.g. a Grafana Cloud stack's \
           instance ID) -- the read-side counterpart of Alloy's external_loki_username \
           (cli/platform/infra/base). Falls back to SOL_LOKI_USERNAME; the flag wins \
           when both are set. Must be paired with --loki-password (or \
           SOL_LOKI_PASSWORD).")
;;

let loki_password_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "loki-password" ]
        ~docv:"PASSWORD"
        ~doc:
          "Basic-auth password/API key for the Loki query request -- the read-side \
           counterpart of Alloy's external_loki_password (cli/platform/infra/base). \
           Falls back to SOL_LOKI_PASSWORD; the flag wins when both are set. Must be \
           paired with --loki-username (or SOL_LOKI_USERNAME). Prefer SOL_LOKI_PASSWORD \
           on shared hosts because command-line flags can be visible in shell history \
           and process listings.")
;;

let follow_term =
  let combine follow no_follow =
    match follow, no_follow with
    | true, true ->
      Printf.eprintf "error: --follow and --no-follow are mutually exclusive\n%!";
      exit 1
    | _, true -> false
    | _, false -> true
  in
  Term.(const combine $ follow_flag $ no_follow_flag)
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
       "logs"
       ~doc:
         "Stream logs from a deployed service. Wraps 'kubectl logs' with Sol's namespace \
          convention (<workspace>-<domain>).")
    Term.(
      const
        (fun
            service_arg
             follow
             tail
             observability_backend
             base_domain
             target
             grafana_base_url
             loki_base_url
             loki_username
             loki_password
           ->
           let explicit_backend = backend_of_arg observability_backend in
           run
             ~service_arg
             ~follow
             ~tail
             ~explicit_backend
             ~explicit_base_domain:base_domain
             ~target
             ~explicit_loki_url:loki_base_url
             ~explicit_loki_username:loki_username
             ~explicit_loki_password:loki_password
             ?grafana_base_url
             ())
      $ service_arg
      $ follow_term
      $ tail_arg
      $ observability_backend_arg
      $ base_domain_arg
      $ target_arg
      $ grafana_base_url_arg
      $ loki_base_url_arg
      $ loki_username_arg
      $ loki_password_arg)
;;
