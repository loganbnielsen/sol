open Cmdliner
open Result.Syntax

let loki_failure_message ~url e =
  match e with
  | Sol_cli_loki.Malformed msg -> msg
  | e ->
    Sol_cli_status.unreachable_message ~url ~error:(Sol_cli_loki.fetch_error_to_string e)
;;

let resolve_unit ~facts ~scope =
  let* selected =
    Sol_cli_workload_selection.resolve
      ~what:"--scope"
      (Some scope)
      (Sol_cli_workspace_model.services facts)
    |> Sol_cli_exit.of_msg
  in
  match selected.request, selected.services with
  | Sol_cli_deployment_scope.Unit_named _, [ svc ] -> Ok svc
  | Sol_cli_deployment_scope.Unit_named _, _ ->
    Error
      (Sol_cli_exit.error
         (Printf.sprintf "--scope %S did not resolve to exactly one workload." scope))
  | _ ->
    Error
      (Sol_cli_exit.error
         "sol logs addresses exactly one unit ('domain/name'); for a domain or workspace \
          view, use 'sol open logs <scope>'.")
;;

let workload_presence ~ctx ~ns ~primitive ~k8s_name =
  let kind =
    match (primitive : Sol_cli_manifest.primitive) with
    | Fn -> "cronjob"
    | Svc | Worker -> "deployment"
  in
  Sol_cli_kubectl.presence
    ~ctx
    ~args:[ "get"; kind; k8s_name; "-n"; ns; "--ignore-not-found" ]
;;

let unit_names ~workspace (svc : Sol_cli_manifest.service) =
  Sol_cli_exit.of_msg
    (let* ns = Sol_cli_deployment_plan.namespace_name ~workspace ~domain:svc.domain in
     let* k8s_name = Sol_cli_deployment_plan.k8s_name svc.name in
     Ok (ns, k8s_name))
;;

let require_workload ~ctx ~ns ~primitive ~k8s_name ~name =
  match workload_presence ~ctx ~ns ~primitive ~k8s_name with
  | Sol_cli_kubectl.Present -> Ok ()
  | Sol_cli_kubectl.Absent _ ->
    Error
      (Sol_cli_exit.failure
         (Printf.sprintf
            "Service %s not found in namespace %s.\n\
             Run 'sol status' to see deployed services."
            name
            ns))
  | Sol_cli_kubectl.Uncheckable why ->
    Error
      (Sol_cli_exit.error
         (Printf.sprintf
            "could not check whether service %s exists in namespace %s: %s"
            name
            ns
            why))
;;

let kubectl_log_target ~primitive ~k8s_name : Sol_cli_logs.kubectl_log_target =
  match (primitive : Sol_cli_manifest.primitive) with
  | Fn -> App_selector k8s_name
  | Svc | Worker -> Deployment k8s_name
;;

let exec_kubectl_logs ~ctx ~ns ~target ~follow ~tail =
  let argv = Sol_cli_logs.kubectl_logs_argv ~ctx ~ns ~target ~follow ~tail in
  let overrides = Sol_cli_kube_destination.context_environment ctx in
  let env =
    if overrides = []
    then Unix.environment ()
    else (
      let keys = List.map fst overrides in
      let base =
        Array.to_list (Unix.environment ())
        |> List.filter (fun entry ->
          match String.index_opt entry '=' with
          | None -> true
          | Some i ->
            let name = String.sub entry 0 i in
            not (List.mem name keys))
      in
      let override_entries = List.map (fun (k, v) -> k ^ "=" ^ v) overrides in
      Array.of_list (base @ override_entries))
  in
  Unix.execvpe "kubectl" (Array.of_list argv) env
;;

type observability_options =
  { backend : Sol_cli_observability_url.backend option
  ; base_domain : string option
  ; grafana_base_url : string option
  ; loki_base_url : string option
  ; loki_username : string option
  ; loki_password : string option
  }

type log_options =
  { scope : string option
  ; release : string option
  ; follow : bool
  ; tail : int
  ; observability : observability_options
  }

let loki_credentials (observability : observability_options) =
  Sol_cli_loki.resolve_credentials
    ~flag_username:observability.loki_username
    ~flag_password:observability.loki_password
    ~env_username:(Sol_cli_string.env "SOL_LOKI_USERNAME")
    ~env_password:(Sol_cli_string.non_empty (Sys.getenv_opt "SOL_LOKI_PASSWORD"))
  |> Sol_cli_exit.of_msg
;;

let backend_and_base_domain ~target (observability : observability_options) =
  Sol_cli_observability_url.effective_backend_and_base_domain
    ~explicit_backend:observability.backend
    ~explicit_base_domain:observability.base_domain
    ~target
    ()
  |> Sol_cli_exit.of_msg
;;

let run_unit ~ctx ~target (options : log_options) scope =
  let { follow; tail; observability; _ } = options in
  let* { root; name = workspace } = Sol_cli_workspace.enter_cwd () in
  let* facts = Sol_cli_workspace_model.load ~root |> Sol_cli_exit.of_msg in
  let* svc = resolve_unit ~facts ~scope in
  let name = svc.name in
  let primitive = svc.primitive in
  let* ns, k8s_name = unit_names ~workspace svc in
  let unit : Sol_cli_log_selector.t =
    { workspace; domain = svc.domain; service = k8s_name }
  in
  let* backend, base_domain = backend_and_base_domain ~target observability in
  (match
     Sol_cli_observability_url.resolve
       ~backend
       ?base_domain
       ?override:observability.grafana_base_url
       ()
   with
   | Sol_cli_observability_url.Url base_url ->
     let url = Sol_cli_logs.grafana_explore_url ~base_url ~unit in
     Printf.printf "Grafana logs: %s\n%!" url
   | Sol_cli_observability_url.No_url reason ->
     Printf.printf "Grafana logs: (%s)\n%!" reason);
  let fallback_to_kubectl () =
    let* () = require_workload ~ctx ~ns ~primitive ~k8s_name ~name in
    (match
       Sol_cli_rollout_diagnosis.diagnose_service_live
         ~ctx
         ~pod_expectation:(Sol_cli_status.pod_expectation_of_primitive primitive)
         ~ns
         ~service_name:name
         ~k8s_name
         ()
     with
     | Sol_cli_rollout_diagnosis.Unhealthy text -> Printf.printf "%s\n%!" text
     | Sol_cli_rollout_diagnosis.Undetermined why ->
       Printf.printf "diagnosis unavailable: %s\n%!" why
     | Sol_cli_rollout_diagnosis.Healthy -> ());
    exec_kubectl_logs
      ~ctx
      ~ns
      ~target:(kubectl_log_target ~primitive ~k8s_name)
      ~follow
      ~tail
  in
  if follow
  then fallback_to_kubectl ()
  else (
    match
      Sol_cli_status.probe_url
        ~backend
        ~explicit_url:observability.loki_base_url
        ~default_local_url:"http://localhost:3100"
        ~probe_path:""
    with
    | None ->
      Printf.printf
        "(%s. Showing Kubernetes logs.)\n%!"
        (Sol_cli_status.not_configured_message ~signal:Sol_cli_status.Loki ~backend);
      fallback_to_kubectl ()
    | Some loki_base_url ->
      let* credentials = loki_credentials observability in
      (match
         Sol_cli_loki.query ~base_url:loki_base_url ~unit ?credentials ~limit:tail ()
       with
       | Ok [] ->
         Printf.printf
           "(no log lines found in Loki for %s; showing Kubernetes logs)\n%!"
           name;
         fallback_to_kubectl ()
       | Ok lines ->
         lines |> List.iter (fun (l : Sol_cli_loki.line) -> print_endline l.text);
         Ok ()
       | Error e ->
         Printf.printf
           "(%s. Falling back to Kubernetes logs for %s...)\n%!"
           (loki_failure_message ~url:loki_base_url e)
           name;
         fallback_to_kubectl ()))
;;

let release_unknown ~release_id ~target records =
  let recent =
    match records with
    | [] -> ""
    | recent ->
      "\nRecent releases: "
      ^ String.concat ", " (List.map (fun (r : Sol_cli_release.t) -> r.release_id) recent)
  in
  Sol_cli_exit.error
    (Printf.sprintf "release %s is not known in target %s%s" release_id target recent)
;;

let run_release ~ctx ~target (options : log_options) release =
  let { tail; observability; _ } = options in
  let* { root; name = workspace } = Sol_cli_workspace.enter_cwd () in
  let target_name = Option.value target ~default:"local" in
  let* unit =
    match options.scope with
    | None -> Ok None
    | Some scope ->
      let* facts = Sol_cli_workspace_model.load ~root |> Sol_cli_exit.of_msg in
      let* svc = resolve_unit ~facts ~scope in
      let* _ns, service = unit_names ~workspace svc in
      Ok (Some { Sol_cli_log_selector.workspace; domain = svc.domain; service })
  in
  let records = lazy (Sol_cli_release_store.list ~ctx ~workspace) in
  let known id =
    match Lazy.force records with
    | Ok records ->
      records
      |> List.exists (fun (r : Sol_cli_release.t) ->
        String.equal r.release_id (Sol_cli_release_id.to_string id))
    | Error _ -> false
  in
  match Sol_cli_logs.release_query ~release ~target:target_name ~known ?unit () with
  | Sol_cli_logs.Release_invalid msg -> Error (Sol_cli_exit.error msg)
  | Sol_cli_logs.Release_unknown { release_id; target } ->
    let* records = Lazy.force records |> Sol_cli_exit.of_msg in
    Error (release_unknown ~release_id ~target records)
  | Sol_cli_logs.Release_logs { release_id; logql } ->
    let* backend, base_domain = backend_and_base_domain ~target observability in
    (match
       Sol_cli_observability_url.resolve
         ~backend
         ?base_domain
         ?override:observability.grafana_base_url
         ()
     with
     | Sol_cli_observability_url.Url base_url ->
       Printf.printf "Grafana logs: %s\n%!" (Sol_cli_logs.explore_url ~base_url ~logql)
     | Sol_cli_observability_url.No_url reason ->
       Printf.printf "Grafana logs: (%s)\n%!" reason);
    (match
       Sol_cli_status.probe_url
         ~backend
         ~explicit_url:observability.loki_base_url
         ~default_local_url:"http://localhost:3100"
         ~probe_path:""
     with
     | None ->
       Printf.printf
         "(%s)\n%!"
         (Sol_cli_status.not_configured_message ~signal:Sol_cli_status.Loki ~backend);
       Ok ()
     | Some loki_base_url ->
       let* credentials = loki_credentials observability in
       (match
          Sol_cli_loki.query_logql
            ~base_url:loki_base_url
            ~logql
            ?credentials
            ~limit:tail
            ()
        with
        | Ok [] ->
          Printf.printf "No log lines found for release %s.\n%!" release_id;
          Ok ()
        | Ok lines ->
          lines |> List.iter (fun (l : Sol_cli_loki.line) -> print_endline l.text);
          Ok ()
        | Error e ->
          Error (Sol_cli_exit.error (loki_failure_message ~url:loki_base_url e))))
;;

let run ~ctx ~target (options : log_options) =
  match options.release, options.scope with
  | Some release, _ -> run_release ~ctx ~target options release
  | None, Some scope -> run_unit ~ctx ~target options scope
  | None, None ->
    Error (Sol_cli_exit.error "pass --scope DOMAIN/UNIT (or --release <id>)")
;;

let scope_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "scope" ]
        ~docv:"DOMAIN/UNIT"
        ~doc:
          "Unit to stream logs from, e.g. payments/charge_svc. Exactly one unit: logs \
           address a single workload, so a domain or workspace scope is not accepted \
           here -- use 'sol open logs' for those views. Optional when --release narrows \
           the query to a released identity.")
;;

let release_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "release" ]
        ~docv:"RELEASE_ID"
        ~doc:
          "Only logs from this release, e.g. r-0123456789abcdef. The id is the \
           content-addressed identity `sol releases` lists and every workload carries as \
           its release label. A malformed id fails closed before the cluster is \
           consulted; a well-formed id with no recorded release fails closed naming \
           recent releases; a known release with no matching lines is an empty result, \
           not an error.")
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
    & opt (some Sol_cli_args.text) None
    & info
        [ "grafana-base-url" ]
        ~docv:"URL"
        ~doc:
          "Override the Grafana base URL instead of resolving it from \
           --observability-backend. Sol prints a copyable Grafana Explore URL with a \
           LogQL query before streaming kubectl logs.")
;;

let observability_backend_arg =
  let backends =
    Sol_cli_observability_url.[ Local; Self_hosted_durable; External ]
    |> List.map (fun b -> Sol_cli_observability_url.backend_to_string b, b)
  in
  Arg.(
    value
    & opt (some (enum backends)) None
    & info
        [ "observability-backend" ]
        ~docv:"BACKEND"
        ~doc:
          "Which observability_backend (see platform/cloud/modules/platform) this target \
           uses: local, self_hosted_durable, or external. Overrides whatever --target's \
           config supplies; defaults to local when neither is given. Determines the \
           Grafana URL Sol resolves when --grafana-base-url is not given.")
;;

let base_domain_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "base-domain" ]
        ~docv:"DOMAIN"
        ~doc:
          "Base domain for the self_hosted_durable backend's Grafana Ingress \
           (grafana.<base-domain>). Overrides whatever --target's config supplies. \
           Required for that backend unless --grafana-base-url overrides it directly.")
;;

let target_arg =
  Sol_cli_target_arg.flag
    ~doc:
      "Deployment target path (same as sol plan/sol deploy, e.g. prod/aws/us-east-1). \
       When given, its sol.yml config supplies the observability_backend/base_domain \
       defaults instead of the hardcoded local default."
;;

let loki_base_url_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
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
    & opt (some Sol_cli_args.text) None
    & info
        [ "loki-username" ]
        ~docv:"USERNAME"
        ~doc:
          "Basic-auth username for the Loki query request (e.g. a Grafana Cloud stack's \
           instance ID) -- the read-side counterpart of Alloy's external_loki_username \
           (platform/cloud/modules/platform). Falls back to SOL_LOKI_USERNAME; the flag \
           wins when both are set. Must be paired with --loki-password (or \
           SOL_LOKI_PASSWORD).")
;;

let loki_password_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "loki-password" ]
        ~docv:"PASSWORD"
        ~doc:
          "Basic-auth password/API key for the Loki query request -- the read-side \
           counterpart of Alloy's external_loki_password \
           (platform/cloud/modules/platform). Falls back to SOL_LOKI_PASSWORD; the flag \
           wins when both are set. Must be paired with --loki-username (or \
           SOL_LOKI_USERNAME). Prefer SOL_LOKI_PASSWORD on shared hosts because \
           command-line flags can be visible in shell history and process listings.")
;;

let follow_term =
  let combine follow no_follow =
    match follow, no_follow with
    | true, true -> `Error (false, "--follow and --no-follow are mutually exclusive")
    | _, no_follow -> `Ok (not no_follow)
  in
  Term.(ret (const combine $ follow_flag $ no_follow_flag))
;;

let observability_options_term =
  Term.(
    const
      (fun
          backend
           base_domain
           grafana_base_url
           loki_base_url
           loki_username
           loki_password
         ->
         { backend
         ; base_domain
         ; grafana_base_url
         ; loki_base_url
         ; loki_username
         ; loki_password
         })
    $ observability_backend_arg
    $ base_domain_arg
    $ grafana_base_url_arg
    $ loki_base_url_arg
    $ loki_username_arg
    $ loki_password_arg)
;;

let run_term ~local ~target_term =
  Term.(
    const (fun scope release follow tail observability target ->
      let result =
        let* ctx =
          if local
          then Ok Cmd_destination.local
          else Cmd_destination.remote ~command:"logs" target
        in
        run ~ctx ~target { scope; release; follow; tail; observability }
      in
      Sol_cli_exit.exit_on result)
    $ scope_arg
    $ release_arg
    $ follow_term
    $ tail_arg
    $ observability_options_term
    $ target_term)
;;

let cmd =
  Cmd.v
    (Cmd.info
       "logs"
       ~doc:
         "Stream logs from a deployed service. Wraps 'kubectl logs' with Sol's namespace \
          convention (<workspace>-<domain>), or filters to one released identity with \
          --release <id>.")
    (run_term ~local:false ~target_term:Cmd_destination.target_arg)
;;

let local_cmd =
  Cmd.v
    (Cmd.info "logs" ~doc:"Stream logs from a workload running on the local cluster")
    (run_term ~local:true ~target_term:(Term.const None))
;;
