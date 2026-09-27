val record
  :  ctx:Sol_cli_kube_destination.context
  -> Sol_cli_deployment.t
  -> (unit, string) result

val list
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> (Sol_cli_deployment.t list, string) result
