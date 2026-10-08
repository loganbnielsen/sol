type kubernetes_status =
  | Not_configured
  | Misconfigured of string * string
  | Configured of string
  | Reachable of string
  | Unreachable of string * string
  | Unreadable of string * string

val describe : verbose:bool -> kubernetes_status -> string
val redact_context : verbose:bool -> context:string -> string -> string
val context_is_configured : Sol_cli_kube_destination.t -> bool
val last_operation_unavailable : string

(** How an operator or a harness obtains cluster access for a target: the cloud
    root's own declared kubeconfig command and the context it writes. *)
type deploy_handoff =
  { command : string
  ; context : string
  }

(** Read the handoff from a cloud root's Terraform outputs. Absent, blank or
    one-sided fields are [None]: the report omits what the root does not declare
    rather than inventing a context or a default. *)
val deploy_handoff_of_outputs : string -> deploy_handoff option

val rows
  :  ?platform:string
  -> ?cloud:string
  -> ?drift:string
  -> ?last_operation:string
  -> ?substrate:(string * string) list
  -> ?deploy_handoff:deploy_handoff
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
  -> ?deploy_handoff:deploy_handoff
  -> verbose:bool
  -> Sol_cli_config.target
  -> kubernetes_status
  -> Yojson.Safe.t
