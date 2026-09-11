open Cmdliner

let try_open_browser url =
  try
    ignore
      (Sys.command (Printf.sprintf "xdg-open %s >/dev/null 2>&1 &" (Filename.quote url)))
  with
  | _ -> ()
;;

let kind_label = function
  | Sol_cli_open.Logs -> "Grafana logs"
  | Sol_cli_open.Metrics -> "Grafana metrics"
  | Sol_cli_open.Dashboard -> "Grafana dashboard"
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

let run kind scope_str links explicit_backend explicit_base_domain target grafana_base_url
  =
  let workspace = Cmd_logs.workspace_name () in
  let scope =
    match Sol_cli_open.parse_scope scope_str with
    | Ok s -> s
    | Error msg ->
      Printf.eprintf "error: %s\n" msg;
      exit 1
  in
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
  | Ok (backend, base_domain) ->
    (match
       Sol_cli_observability_url.resolve
         ~backend
         ?base_domain
         ?override:grafana_base_url
         ()
     with
     | Sol_cli_observability_url.No_url reason ->
       Printf.printf "%s: (%s)\n%!" (kind_label kind) reason
     | Sol_cli_observability_url.Url base_url ->
       (match Sol_cli_open.url ~base_url ~workspace ~kind scope with
        | Error msg ->
          Printf.eprintf "error: %s\n" msg;
          exit 1
        | Ok url ->
          Printf.printf "%s\n%!" url;
          if not links then try_open_browser url))
;;

let scope_arg =
  Arg.(
    value
    & pos 0 (some string) None
    & info
        []
        ~docv:"SCOPE"
        ~doc:
          "Scope to open: omit for the workspace view, 'domain' for a domain, \
           'domain/service' for a single service, or 'resource/<type>/<name>' for a \
           managed infrastructure resource dashboard (OBS-044), e.g. \
           'resource/rds/acme-prod-postgres'.")
;;

let links_flag =
  Arg.(
    value
    & flag
    & info [ "links" ] ~doc:"Print the raw URL only; don't attempt to open a browser.")
;;

let make_subcmd name kind doc =
  Cmd.v
    (Cmd.info name ~doc)
    Term.(
      const (fun scope_str links backend base_domain target grafana_base_url ->
        run
          kind
          scope_str
          links
          (backend_of_arg backend)
          base_domain
          target
          grafana_base_url)
      $ scope_arg
      $ links_flag
      $ Cmd_logs.observability_backend_arg
      $ Cmd_logs.base_domain_arg
      $ Cmd_logs.target_arg
      $ Cmd_logs.grafana_base_url_arg)
;;

let cmd =
  Cmd.group
    (Cmd.info
       "open"
       ~doc:"Open Grafana logs, metrics, or dashboard views for the workspace.")
    [ make_subcmd
        "logs"
        Sol_cli_open.Logs
        "Open (or print) the Grafana Explore logs view."
    ; make_subcmd
        "metrics"
        Sol_cli_open.Metrics
        "Open (or print) the Grafana metrics dashboard."
    ; make_subcmd
        "dashboard"
        Sol_cli_open.Dashboard
        "Open (or print) the Grafana workspace/service dashboard."
    ]
;;
