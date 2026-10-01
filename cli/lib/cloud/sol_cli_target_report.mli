type kubernetes_status =
  | Not_configured
  | Configured of string
  | Reachable of string
  | Unreachable of string * string
  | Unreadable of string * string

val describe : verbose:bool -> kubernetes_status -> string
val redact_context : verbose:bool -> context:string -> string -> string
val context_is_configured : Sol_cli_kube_destination.t -> bool
val last_operation_unavailable : string

val rows
  :  ?platform:string
  -> ?cloud:string
  -> ?drift:string
  -> ?last_operation:string
  -> ?substrate:(string * string) list
  -> verbose:bool
  -> Sol_cli_config.target
  -> kubernetes_status
  -> (string * string) list

val to_json
  :  ?platform:string
  -> ?cloud:string
  -> ?drift:string
  -> ?last_operation:string
  -> ?substrate:(string * string) list
  -> verbose:bool
  -> Sol_cli_config.target
  -> kubernetes_status
  -> Yojson.Safe.t
