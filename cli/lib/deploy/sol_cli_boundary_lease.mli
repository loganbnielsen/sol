type holder =
  | Deploy
  | Rollback

val holder_to_string : holder -> string
val holder_of_string : string -> (holder, string) result

type t =
  { boundary : string
  ; holder : holder
  ; run_id : string
  ; started_at : float
  ; heartbeat_at : float
  ; abort_requested : bool
  ; abort_reason : string option
  }

val default_ttl_s : float
val rollback_wait_s : float
val configmap_name : workspace:string -> string
val make_run_id : holder:holder -> now:float -> pid:int -> string
val create : boundary:string -> holder:holder -> run_id:string -> now:float -> t
val with_heartbeat : t -> now:float -> t
val with_abort_requested : t -> reason:string -> t
val is_stale : now:float -> ttl:float -> t -> bool
val describe : t -> string

type decision =
  | Proceed
  | Request_abort of string
  | Refuse of string

val deploy_decision : now:float -> ttl:float -> t option -> decision
val rollback_decision : now:float -> ttl:float -> t option -> decision
val to_configmap_json : ?resource_version:string -> t -> string
val of_configmap_item : Yojson.Safe.t -> (t * string, string) result

type write_error =
  | Already_exists
  | Conflict
  | Other of string

val create_object
  :  ctx:Sol_cli_kube_destination.context
  -> t
  -> (unit, write_error) result

val replace_object
  :  ctx:Sol_cli_kube_destination.context
  -> t
  -> resource_version:string
  -> (unit, write_error) result

val fetch
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> ((t * string) option, string) result

val remove
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> (unit, string) result

type held

val acquire
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> holder:holder
  -> ttl:float
  -> wait_s:float
  -> (held, string) result

type heartbeat_result =
  | Held
  | Aborted of string

val heartbeat : held -> (heartbeat_result, string) result
val ensure_held : held -> (unit, string) result
val release : held -> (unit, string) result
val release_with_warning : held -> unit

val with_boundary_lease
  :  ctx:Sol_cli_kube_destination.context
  -> workspace:string
  -> holder:holder
  -> ttl:float
  -> wait_s:float
  -> (held -> ('a, string) result)
  -> ('a, string) result
