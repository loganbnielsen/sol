val name : string
val registry_port : int
val version_gt : string -> string -> bool
val api_version_env : daemon_min:string -> (string * string) list
val exists : unit -> bool
val provision : unit -> (unit, string) result
val delete : unit -> (unit, string) result

type presence =
  | Cluster_present
  | Cluster_absent
  | Cluster_unobservable of string

val observe : unit -> presence
val confirm_removed : unit -> (unit, string) result
