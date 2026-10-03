type outcome =
  | Applied
  | Apply_failed

type t =
  { deployment_id : Sol_cli_deployment_id.t
  ; release_id : Sol_cli_release_id.t
  ; workspace : string
  ; environment : string option
  ; created_at : string
  ; git_commit : string
  ; git_dirty : bool
  ; actor : string option
  ; actor_source : string option
  ; target : string option
  ; mode : string
  ; requested_scope : string
  ; profile : Sol_cli_profile.t option
  ; outcome : outcome
  }

val rfc3339_utc : float -> string

val of_plan
  :  ?release_id:Sol_cli_release_id.t
  -> deployment_id:Sol_cli_deployment_id.t
  -> now:float
  -> git_commit:string
  -> git_dirty:bool
  -> actor:string option
  -> actor_source:string option
  -> target:string option
  -> outcome:outcome
  -> Sol_cli_deployment_plan.t
  -> t

val git_commit : unit -> string
val git_dirty : unit -> bool
val configmap_name : t -> string
val validate : name:string -> t -> (unit, string) result
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
val to_configmap_json : t -> string
val parse_kubectl_list : Yojson.Safe.t -> (t list, string) result
val format_table : t list -> string
