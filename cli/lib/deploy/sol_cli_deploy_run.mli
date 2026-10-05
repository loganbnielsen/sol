type context =
  { execution : Sol_cli_execution.context
  ; sha : string
  ; registry : string
  ; facts : Sol_cli_workspace_model.t
  ; secret_backend : Sol_cli_manifest.secret_backend
  ; emit_plan_to : string option
  ; target_cfg : Sol_cli_config.target
  ; resolved_config : Sol_cli_config.t
  ; services : Sol_cli_manifest.service list
  ; inventory : Sol_cli_manifest.service list
  ; image_refs : (string * string) list
  ; requested_scope : string
  ; target_name : string
  ; run_log : Sol_cli_run_log.t
  ; keep_releases : int
  }

val http_services
  :  ctx:Sol_cli_kube_destination.context
  -> Sol_cli_executor.result list
  -> string list

val verify_image_refs_exist : image_refs:(string * string) list -> (unit, string) result

val observe_contract
  :  context
  -> Sol_cli_deployment_plan.t
  -> (Sol_cli_deployment_plan.t, string) result

val run_plan_result
  :  context
  -> phase:string
  -> mode:Sol_cli_executor.mode
  -> ?before_apply:(Sol_cli_deployment_plan.service_spec -> (unit, string) result)
  -> Sol_cli_deployment_plan.t
  -> (Sol_cli_executor.result list, string) result

type gate_failure =
  | Refused of string
  | Failed of string

val migration_prerequisite
  :  context
  -> plan:Sol_cli_deployment_plan.t
  -> live:bool
  -> (unit, gate_failure) result

val substrate_prerequisite
  :  context
  -> plan:Sol_cli_deployment_plan.t
  -> live:bool
  -> (unit, gate_failure) result

val deploy_events
  :  workspace:string
  -> target_cfg:Sol_cli_config.target
  -> deployment_id:Sol_cli_deployment_id.t
  -> ?release_id:Sol_cli_release_id.t
  -> Sol_cli_deployment_plan.t
  -> Sol_cli_deploy_event.t list

val surplus_workloads
  :  context
  -> Sol_cli_deployment_plan.t
  -> Sol_cli_rollback.workload_identity list

val confirm_consumer_groups
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> confirm_group_change:bool
  -> Sol_cli_deployment_plan.t
  -> (unit, string) result

val apply
  :  context
  -> prepare_plan:(Sol_cli_deployment_plan.t -> (unit, string) result)
  -> push_events:(Sol_cli_deploy_event.t list -> unit)
  -> report_success:(Sol_cli_deployment_plan.t -> Sol_cli_executor.result list -> unit)
  -> confirm_group_change:bool
  -> Sol_cli_deployment_plan.t
  -> (unit, string) result
