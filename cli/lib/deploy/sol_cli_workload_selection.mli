type resolved =
  { request : Sol_cli_deployment_scope.request
  ; requested_scope : string
  ; scope : Sol_cli_deployment_scope.t
  ; services : Sol_cli_manifest.service list
  }

val named_of_services
  :  Sol_cli_manifest.service list
  -> Sol_cli_deployment_scope.named list

val resolve
  :  ?what:string
  -> string option
  -> Sol_cli_manifest.service list
  -> (resolved, string) result

val resolve_nonempty
  :  ?what:string
  -> none:string
  -> string option
  -> Sol_cli_manifest.service list
  -> (resolved, string) result

val is_empty : resolved -> bool

type omission =
  { selected : Sol_cli_manifest.service list
  ; excluded : Sol_cli_manifest.service list
  ; included : Sol_cli_manifest.service list
  }

val apply_omission : is_omitted:(Sol_cli_manifest.service -> bool) -> resolved -> omission
