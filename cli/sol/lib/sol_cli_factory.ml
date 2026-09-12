(* CODE_LAYER-018: internal factory boundary.

   This is the Cmdliner-free entry point that hosted mode will call. It composes
   the existing internal stages into one typed pipeline:

     workspace scan -> deployment plan -> execution -> release facts

   CLI commands can keep their current UX and delegate their plan/execute steps
   here; hosted HTTP handlers can call the same functions without pulling in any
   command-line parsing state. *)

(** Plan plus the per-service results produced by executing it. Release
    inspection and telemetry can be built from this without re-reading
    command-local state. *)
type execution =
  { plan : Sol_cli_deployment_plan.t
  ; results : Sol_cli_executor.result list
  }

let plan_of_services ~workspace ~env ?requested_scope ?resolved_config services =
  Sol_cli_deployment_plan.of_services_result
    ~workspace
    ~env
    ?requested_scope
    ?resolved_config
    services
  |> Result.map_error Sol_cli_deployment_plan.plan_error_to_string
;;

let execute ~workspace ?env ~mode ?secret_backend plan =
  Sol_cli_executor.run_plan
    ~workspace
    ?env
    ~mode
    ?secret_backend
    plan.Sol_cli_deployment_plan.services
;;

(* [services] is already resolved: selection happens once, at the command (or
   hosted-handler) boundary, via [Sol_cli_workload_selection] (FEAT-065). The
   factory no longer scans the workspace, so it cannot quietly select a
   different set than the caller asked for. *)
let run ~workspace ~env ?env_label ?requested_scope ?resolved_config ~mode services () =
  match plan_of_services ~workspace ~env ?requested_scope ?resolved_config services with
  | Error msg -> Error msg
  | Ok plan ->
    (match execute ~workspace ?env:env_label ~mode plan with
     | Error msg -> Error msg
     | Ok results -> Ok { plan; results })
;;

let affected_services ~plan ~results =
  if List.length plan.Sol_cli_deployment_plan.services <> List.length results
  then invalid_arg "Sol_cli_factory.affected_services: plan/results length mismatch";
  List.map2
    (fun (spec : Sol_cli_deployment_plan.service_spec)
      (result : Sol_cli_executor.result) ->
       Sol_cli_release_inspection.affected_service
         ~image:result.Sol_cli_executor.image
         spec)
    plan.Sol_cli_deployment_plan.services
    results
;;
