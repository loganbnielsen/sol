val record
  :  ctx:Sol_cli_kube_destination.context
  -> Sol_cli_release.t
  -> (unit, string) result

val record_plan
  :  ctx:Sol_cli_kube_destination.context
  -> apply_mode:Sol_cli_release.apply_mode
  -> Sol_cli_deployment_plan.t
  -> (unit, string) result

val list
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> (Sol_cli_release.t list, string) result

val list_with_creation
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> ((Sol_cli_release.t * string) list, string) result

val get
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> release_id:string
  -> (Sol_cli_release.t, string) result

val current
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> (string option, string) result

val delete
  :  ctx:Sol_cli_kube_destination.context
  -> release_id:string
  -> (unit, string) result

val move_pointer
  :  ctx:Sol_cli_kube_destination.context
  -> Sol_cli_release.t
  -> (unit, string) result
