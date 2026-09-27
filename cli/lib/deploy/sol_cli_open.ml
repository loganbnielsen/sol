type scope =
  | Workspace
  | Domain of string
  | Service of string * string
  | Resource of string * string

type kind =
  | Logs
  | Metrics
  | Dashboard

let parse_scope = function
  | None -> Ok Workspace
  | Some s ->
    (match String.split_on_char '/' s with
     | [ domain ] -> Ok (Domain domain)
     | [ domain; service ] -> Ok (Service (domain, service))
     | [ "resource"; resource_type; resource_name ] ->
       Ok (Resource (resource_type, resource_name))
     | _ ->
       Error
         (Printf.sprintf
            "scope must be 'domain', 'domain/service', or 'resource/<type>/<name>', got \
             %S"
            s))
;;

let dashboard_url ~base_url ~workspace scope =
  let workspace = Sol_cli_kubernetes_name.sanitize_label_value workspace in
  match scope with
  | Workspace ->
    Ok (Printf.sprintf "%s/d/sol-workspace-overview?var-workspace=%s" base_url workspace)
  | Domain domain ->
    let domain = Sol_cli_kubernetes_name.sanitize_label_value domain in
    Ok
      (Printf.sprintf
         "%s/d/sol-service-template?var-workspace=%s&var-domain=%s"
         base_url
         workspace
         domain)
  | Service (domain, service) ->
    let domain = Sol_cli_kubernetes_name.sanitize_label_value domain in
    (match Sol_cli_deployment_plan.k8s_name_result service with
     | Error e -> Error (Sol_cli_deployment_plan.plan_error_to_string e)
     | Ok k8s_name ->
       let service = Sol_cli_deployment_plan.k8s_name_to_string k8s_name in
       Ok
         (Printf.sprintf
            "%s/d/sol-service-template?var-workspace=%s&var-domain=%s&var-service=%s"
            base_url
            workspace
            domain
            service))
  | Resource (resource_type, resource_name) ->
    if Sol_cli_string.is_blank resource_type
    then Error "resource type must not be empty (expected 'resource/<type>/<name>')"
    else if Sol_cli_string.is_blank resource_name
    then Error "resource name must not be empty (expected 'resource/<type>/<name>')"
    else (
      let resource_type = Sol_cli_kubernetes_name.sanitize_label_value resource_type in
      let resource_name = Sol_cli_kubernetes_name.sanitize_label_value resource_name in
      Ok
        (Printf.sprintf
           "%s/d/sol-managed-resource-%s?var-resource=%s"
           base_url
           resource_type
           resource_name))
;;

let logs_url ~base_url ~workspace scope =
  let label_value = Sol_cli_kubernetes_name.sanitize_label_value in
  match scope with
  | Workspace ->
    Ok
      (Sol_cli_logs.explore_url
         ~base_url
         ~logql:(Printf.sprintf {|{workspace="%s"}|} (label_value workspace)))
  | Domain domain ->
    (match Sol_cli_deployment_plan.namespace_result ~workspace ~domain with
     | Error e -> Error (Sol_cli_deployment_plan.plan_error_to_string e)
     | Ok _ ->
       Ok
         (Sol_cli_logs.explore_url
            ~base_url
            ~logql:
              (Printf.sprintf
                 {|{workspace="%s", domain="%s"}|}
                 (label_value workspace)
                 (label_value domain))))
  | Service (domain, name) ->
    (match
       ( Sol_cli_deployment_plan.namespace_result ~workspace ~domain
       , Sol_cli_deployment_plan.k8s_name_result name )
     with
     | Error e, _ | _, Error e -> Error (Sol_cli_deployment_plan.plan_error_to_string e)
     | Ok _ns, Ok k8s_name ->
       let k8s_name = Sol_cli_deployment_plan.k8s_name_to_string k8s_name in
       Ok (Sol_cli_logs.grafana_explore_url ~base_url ~k8s_name))
  | Resource (resource_type, _) ->
    Error
      (Printf.sprintf
         "no logs view for managed resource type %S -- managed resources don't ship \
          through Sol's Loki pipeline; use 'sol open dashboard' or check the provider's \
          own console"
         resource_type)
;;

let url ~base_url ~workspace ~kind scope =
  match kind with
  | Logs -> logs_url ~base_url ~workspace scope
  | Metrics | Dashboard -> dashboard_url ~base_url ~workspace scope
;;
