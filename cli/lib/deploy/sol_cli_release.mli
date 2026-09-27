type workload = Sol_cli_release_id.workload

type apply_mode =
  | Direct
  | Gitops

val apply_mode_to_string : apply_mode -> string
val apply_mode_of_string : string -> (apply_mode, string) result

type t =
  { release_id : string
  ; workspace : string
  ; environment : string option
  ; workloads : workload list
  ; migrations : string list
  ; apply_mode : apply_mode
  }

val sanitize_label : string -> string
val configmap_name : t -> string
val current_configmap_name : workspace:string -> string
val of_plan : apply_mode:apply_mode -> Sol_cli_deployment_plan.t -> t
val content_of_record : t -> Sol_cli_release_id.content
val derived_release_id : t -> Sol_cli_release_id.t
val validate : name:string -> t -> (unit, string) result
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
val record_json_string : t -> string
val record_digest : t -> string
val bundle_files : t -> (string * string) list
val to_configmap_json : t -> string
val to_current_configmap_json : t -> string
val of_kubectl_item : Yojson.Safe.t -> (t, string) result
val parse_kubectl_list : Yojson.Safe.t -> (t list, string) result
val parse_kubectl_list_with_creation : Yojson.Safe.t -> ((t * string) list, string) result
val format_table : t list -> string

val finish_deployment
  :  record_release:(unit -> (unit, string) result)
  -> report_success:(unit -> unit)
  -> (unit, string) result
