type mode =
  | Local
  | Customer_cloud
  | Sol_hosted

type action_result =
  | Applied of string list
  | Deleted of string list
  | Listed of string list
  | Hosted_unavailable of string

val mode_of_env : string -> (mode, string) result
val validate_key : string -> (unit, string) result

val secret_manifest
  :  existing_data:(string * string) list
  -> namespace:string
  -> key:string
  -> value:string
  -> string

val redacted_result : action_result -> string

(** FEAT-063: each operation runs against the cluster [ctx] names.

    SEC-004: [set] is also the rotation path. Because workloads receive secrets
    as environment variables, a running pod never observes a new value, so [set]
    restarts every live workload in the namespace and waits for [rollout status]
    to confirm it returned to healthy state. A workload that never becomes
    healthy fails the whole operation rather than reporting a silent success. *)
val set
  :  ctx:Sol_cli_kube_destination.context
  -> env:string
  -> workspace:string
  -> namespaces:string list
  -> key:string
  -> value:string
  -> (action_result, string) result

val list
  :  ctx:Sol_cli_kube_destination.context
  -> env:string
  -> workspace:string
  -> namespaces:string list
  -> (action_result, string) result

val delete
  :  ctx:Sol_cli_kube_destination.context
  -> env:string
  -> workspace:string
  -> namespaces:string list
  -> key:string
  -> (action_result, string) result
