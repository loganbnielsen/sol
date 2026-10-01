type kubernetes_status =
  | Not_configured
  | Configured of string
  | Reachable of string
  | Unreachable of string * string

val describe : verbose:bool -> kubernetes_status -> string
val context_is_configured : Sol_cli_kube_destination.t -> bool

val rows
  :  ?platform:string
  -> verbose:bool
  -> Sol_cli_config.target
  -> kubernetes_status
  -> (string * string) list

val to_json
  :  ?platform:string
  -> verbose:bool
  -> Sol_cli_config.target
  -> kubernetes_status
  -> Yojson.Safe.t
