type set_val =
  | Bool of bool
  | Float of float
  | Str of string

val repo_add
  :  name:string
  -> url:string
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val repo_update : unit -> (Sol_cli_process.output, Sol_cli_process.error) result

val upgrade_install_argv
  :  ctx:Sol_cli_kube_destination.context
  -> release:string
  -> chart:string
  -> namespace:string
  -> ?version:string
  -> ?values:(string * set_val) list
  -> ?values_file:string
  -> unit
  -> string list

val upgrade_install
  :  ctx:Sol_cli_kube_destination.context
  -> release:string
  -> chart:string
  -> namespace:string
  -> ?version:string
  -> ?values:(string * set_val) list
  -> ?values_yaml:string
  -> unit
  -> (Sol_cli_process.output, Sol_cli_process.error) result
