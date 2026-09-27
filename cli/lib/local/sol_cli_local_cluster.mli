val name : string
val registry_port : int
val version_gt : string -> string -> bool
val api_version_env : daemon_min:string -> (string * string) list
val exists : unit -> bool
val provision : unit -> (unit, string) result
val delete : unit -> unit
