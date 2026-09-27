type resolved =
  { request : Sol_cli_deployment_scope.request
  ; requested_scope : string
  ; scope : Sol_cli_deployment_scope.t
  ; services : Sol_cli_manifest.service list
  }

let named_of_service (svc : Sol_cli_manifest.service) : Sol_cli_deployment_scope.named =
  { Sol_cli_deployment_scope.domain = svc.domain
  ; name = svc.name
  ; kind =
      (match svc.primitive with
       | Sol_cli_manifest.Svc -> Sol_cli_deployment_scope.Service
       | Sol_cli_manifest.Worker -> Sol_cli_deployment_scope.Worker
       | Sol_cli_manifest.Fn -> Sol_cli_deployment_scope.Function)
  }
;;

let named_of_services services = List.map named_of_service services

let service_is_selected
      (selected : Sol_cli_deployment_scope.named list)
      (svc : Sol_cli_manifest.service)
  =
  selected
  |> List.exists (fun (unit_ : Sol_cli_deployment_scope.named) ->
    Sol_cli_deployment_scope.equal_name svc.domain unit_.domain
    && Sol_cli_deployment_scope.equal_name svc.name unit_.name)
;;

let services_of_selection services selected =
  List.filter (service_is_selected selected) services
;;

let resolve ?(what = "--scope") scope_value services =
  match Sol_cli_deployment_scope.parse_request ~what scope_value with
  | Error _ as err -> err
  | Ok request ->
    let requested_scope = Sol_cli_deployment_scope.request_to_string request in
    (match
       Sol_cli_deployment_scope.resolve ~what request (named_of_services services)
     with
     | Error _ as err -> err
     | Ok (scope, Sol_cli_deployment_scope.Selected selected) ->
       Ok
         { request
         ; requested_scope
         ; scope
         ; services = services_of_selection services selected
         }
     | Ok (scope, Sol_cli_deployment_scope.Empty) ->
       Ok { request; requested_scope; scope; services = [] })
;;

let resolve_nonempty ?what ~none scope_value services =
  match resolve ?what scope_value services with
  | Ok { services = []; _ } -> Error none
  | result -> result
;;

let is_empty (resolved : resolved) = resolved.services = []

type omission =
  { selected : Sol_cli_manifest.service list
  ; excluded : Sol_cli_manifest.service list
  ; included : Sol_cli_manifest.service list
  }

let apply_omission ~is_omitted (resolved : resolved) =
  let omitted, kept = List.partition is_omitted resolved.services in
  match resolved.request with
  | Sol_cli_deployment_scope.Unit_named _ ->
    { selected = resolved.services; excluded = []; included = omitted }
  | Sol_cli_deployment_scope.Whole_workspace | Sol_cli_deployment_scope.Whole_domain _ ->
    { selected = kept; excluded = omitted; included = [] }
;;
