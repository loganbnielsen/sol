val namespaces : Sol_cli_deployment_plan.t -> string list

val docs
  :  ?secrets:(string * string) list
  -> Sol_cli_deployment_plan.t
  -> (Sol_cli_yaml.document list, string) result

val docs_for_namespaces
  :  ?secrets:(string * string) list
  -> string list
  -> (Sol_cli_yaml.document list, string) result

val ensure
  :  ctx:Sol_cli_kube_destination.context
  -> namespaces:string list
  -> (unit, string) result

val operator_binding_docs
  :  workspace:string
  -> Sol_cli_manifest.service list
  -> Sol_cli_yaml.document list

val reconcile_operator_bindings
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> services:Sol_cli_manifest.service list
  -> (unit, string) result
