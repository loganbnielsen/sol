(** Sol's local k3d cluster (REFAC-139, part F). *)

val name : string
val registry_port : int

(** [version_gt a b]: dotted version [a] is later than [b], numerically per
    component, with a missing component read as 0. *)
val version_gt : string -> string -> bool

(** [api_version_env ~daemon_min]: FRIC-017's [DOCKER_API_VERSION] for k3d --
    the daemon's minimum API when it is above k3d's own 1.43 floor, else
    nothing. *)
val api_version_env : daemon_min:string -> (string * string) list

val exists : unit -> bool

(** Create the cluster with its registry unless it already exists. A pre-rename
    [sun-local] cluster is refused by name (FRIC-008); a failed create carries
    k3d's own output (FRIC-006). *)
val provision : unit -> (unit, string) result

(** Delete the cluster; a failure is ignored, as [sol local infra down] always
    did. *)
val delete : unit -> unit
