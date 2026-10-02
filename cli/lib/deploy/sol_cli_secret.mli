type action_result =
  | Applied of string list
  | Deleted of string list
  | Listed of string list

val validate_key_format : string -> (unit, string) result
val validate_key : string -> (unit, string) result

val secret_manifest
  :  existing_data:(string * string) list
  -> namespace:string
  -> key:string
  -> value:string
  -> string

val redacted_result : action_result -> string

val set
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> namespaces:string list
  -> declared:(string * string) list
  -> key:string
  -> value:string
  -> (action_result, string) result

val list
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> namespaces:string list
  -> (action_result, string) result

val delete
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> namespaces:string list
  -> key:string
  -> (action_result, string) result

val verify_required_keys
  :  ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> secret_name:string
  -> required_keys:string list
  -> (unit, string) result

val verify_workload_secret
  :  ctx:Sol_cli_kube_destination.context
  -> Sol_cli_deployment_plan.service_spec
  -> (unit, string) result

val verify_runtime_secret
  :  ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> (unit, string) result
