open Cmdliner

let try_open_browser url =
  ignore (Sol_cli_process.spawn (Sol_cli_process.cmd [ "xdg-open"; url ]))
;;

let kind_label = function
  | Sol_cli_open.Logs -> "Grafana logs"
  | Sol_cli_open.Traces -> "Grafana traces"
  | Sol_cli_open.Metrics -> "Grafana metrics"
  | Sol_cli_open.Dashboard -> "Grafana dashboard"
  | Sol_cli_open.Infra -> "Grafana infrastructure"
;;

open Result.Syntax

let provider_console ~kind target =
  if not (Sol_cli_open.requires_target kind)
  then Ok None
  else (
    match target with
    | None -> Ok None
    | Some target_path ->
      Sol_cli_config.load_for_target ~target:target_path
      |> Result.map (fun config ->
        Sol_cli_provider_capabilities.provider_console_url config.Sol_cli_config.target)
      |> Sol_cli_exit.of_error Sol_cli_config.error_to_string)
;;

let run kind scope_str links (observability : Cmd_logs.observability_options) target =
  let* { name = workspace; _ } = Sol_cli_workspace.enter_cwd () in
  let* scope = Sol_cli_open.parse_scope scope_str |> Sol_cli_exit.of_msg in
  let* () =
    Sol_cli_open.validate ~kind ~target_present:(Option.is_some target) scope
    |> Sol_cli_exit.of_msg
  in
  let* console = provider_console ~kind target in
  let* backend, base_domain = Cmd_logs.backend_and_base_domain ~target observability in
  match
    Sol_cli_observability_url.resolve
      ~backend
      ?base_domain
      ?override:observability.Cmd_logs.grafana_base_url
      ()
  with
  | Sol_cli_observability_url.No_url reason ->
    Printf.printf "%s: (%s)\n%!" (kind_label kind) reason;
    Ok ()
  | Sol_cli_observability_url.Url base_url ->
    let* url = Sol_cli_open.url ~base_url ~workspace ~kind scope |> Sol_cli_exit.of_msg in
    Printf.printf "%s\n%!" url;
    console |> Option.iter (Printf.printf "%s\n%!");
    if not links then try_open_browser url;
    Ok ()
;;

let scope_doc =
  "Scope to open: omit for the workspace view, 'domain' for a domain, 'domain/service' \
   for a single service, or 'resource/<type>/<name>' for a managed infrastructure \
   resource dashboard (OBS-044), e.g. 'resource/rds/acme-prod-postgres'."
;;

let scope_arg doc =
  Arg.(value & pos 0 (some Sol_cli_args.text) None & info [] ~docv:"SCOPE" ~doc)
;;

let links_flag =
  Arg.(
    value
    & flag
    & info [ "links" ] ~doc:"Print the raw URL only; don't attempt to open a browser.")
;;

let observability_term =
  Term.(
    const (fun backend base_domain grafana_base_url ->
      { Cmd_logs.backend
      ; base_domain
      ; grafana_base_url
      ; loki_base_url = None
      ; loki_username = None
      ; loki_password = None
      })
    $ Cmd_logs.observability_backend_arg
    $ Cmd_logs.base_domain_arg
    $ Cmd_logs.grafana_base_url_arg)
;;

let make_subcmd ?(scope_doc = scope_doc) name kind doc =
  Cmd.v
    (Cmd.info name ~doc)
    Term.(
      const Sol_cli_exit.exit_on
      $ (const (run kind)
         $ scope_arg scope_doc
         $ links_flag
         $ observability_term
         $ Cmd_logs.target_arg))
;;

let cmd =
  Cmd.group
    (Cmd.info
       "open"
       ~doc:
         "Open Grafana logs, traces, metrics, dashboard, or target-infrastructure views.")
    [ make_subcmd
        "logs"
        Sol_cli_open.Logs
        "Open (or print) the Grafana Explore logs view."
    ; make_subcmd
        "traces"
        Sol_cli_open.Traces
        "Open (or print) the Grafana Explore traces view, scoped by the workload \
         identity the spans carry (workspace, domain and the unit's service name)."
    ; make_subcmd
        "metrics"
        Sol_cli_open.Metrics
        "Open (or print) the Grafana metrics dashboard."
    ; make_subcmd
        "dashboard"
        Sol_cli_open.Dashboard
        "Open (or print) the Grafana workspace/service dashboard."
    ; make_subcmd
        "infra"
        Sol_cli_open.Infra
        "Open (or print) the target-scoped infrastructure view — nodes and capacity, the \
         platform's resource utilization, the observability stack, Redpanda, and \
         Postgres — and the target's provider console. Unlike the scope-addressed views \
         this one is addressed by target: it requires --target and takes no scope \
         (DEC-031, DEC-032)."
        ~scope_doc:
          "Not accepted: infrastructure has no application scope, so this view is \
           addressed by --target alone. Passing a scope fails naming the view as \
           target-scoped rather than being ignored (DEC-032)."
    ]
;;
