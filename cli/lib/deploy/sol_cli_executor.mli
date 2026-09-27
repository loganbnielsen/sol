type result =
  { namespace : string
  ; name : string
  ; image : string
  }

type mode =
  | Dry_run
  | Emit_to of string
  | Apply

val local
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> release_id:Sol_cli_release_id.t
  -> dry_run:bool
  -> Sol_cli_deployment_plan.service_spec
  -> (result, string) Stdlib.result

val gitops
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> release_id:Sol_cli_release_id.t
  -> dir:string
  -> ?secret_backend:Sol_cli_manifest.secret_backend
  -> Sol_cli_deployment_plan.service_spec
  -> (result, string) Stdlib.result

val run_plan
  :  Sol_cli_execution.context
  -> mode:mode
  -> ?secret_backend:Sol_cli_manifest.secret_backend
  -> ?before_apply:(Sol_cli_deployment_plan.service_spec -> (unit, string) Stdlib.result)
  -> Sol_cli_deployment_plan.t
  -> (result list, string) Stdlib.result

val local_development_spec
  :  Sol_cli_deployment_plan.service_spec
  -> Sol_cli_deployment_plan.service_spec
