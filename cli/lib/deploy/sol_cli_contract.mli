type mode =
  | Check
  | Apply
  | Projection

type declared_event =
  { module_name : string
  ; topic : string
  ; partitions : int
  }

val decode_declared_contract : string -> (declared_event list, string) result

val run
  :  echo:bool
  -> workspace:string
  -> registry_url:string
  -> mode:mode
  -> (string option, string) result

val has_projection : workspace:string -> bool
val report : workspace:string -> registry_url:string -> mode:mode -> (unit, string) result
val plan_report : workspace:string -> registry_url:string option -> (unit, string) result
val scope_has_ocaml : Sol_cli_deployment_plan.service_spec list -> bool

val ocaml_reconciliation_image
  :  Sol_cli_deployment_plan.service_spec list
  -> (string * string) option

val reconcile_in_destination
  :  ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> image:string
  -> (unit, string) result
