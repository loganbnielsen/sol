type secret_backend =
  | Kubernetes_live
  | Kubernetes_placeholder
  | External_secrets of
      { store_ref : string
      ; store_kind : string
      ; key_prefix : string
      ; refresh_interval : string
      }

val secret_backend_to_string : secret_backend -> string

type primitive =
  | Svc
  | Worker
  | Fn

type service =
  { domain : string
  ; name : string
  ; primitive : primitive
  ; dir : string
  }

type workload_fact = service * bool
type unexpected = string * string * string

type workspace_scan =
  { workloads : workload_fact list
  ; unexpected : unexpected list
  }

type discover_error =
  | Missing_app_dir
  | Workspace_error of Sol_cli_workspace.workspace_error

val workload_fact_to_service : workload_fact -> service
val scan_workspace : ?root:string -> unit -> (workspace_scan, discover_error) result
val primitive_of_suffix : string -> primitive option
val primitive_label : primitive -> string
val discover_error_to_string : discover_error -> string
val discover_services : ?root:string -> unit -> (service list, discover_error) result
val default_cluster_env : (string * string) list
val default_secrets : (string * string) list
val runtime_secret_name : string
val workload_secret_name : string -> string
val config_hash : (string * string) list -> string
val sanitize_label_value : string -> string
val namespace_doc : ns:string -> Sol_cli_yaml.document
val deploy_role_binding_doc : ns:string -> Sol_cli_yaml.document
val operator_role_binding_doc : ns:string -> Sol_cli_yaml.document
val service_account_doc : ns:string -> name:string -> Sol_cli_yaml.document
val pdb_doc : ns:string -> name:string -> replicas:int -> Sol_cli_yaml.document

val configmap_doc
  :  ?extra_env:(string * string) list
  -> ns:string
  -> name:string
  -> unit
  -> Sol_cli_yaml.document

val secret_doc
  :  ?base_secrets:(string * string) list
  -> ?extra_secrets:(string * string) list
  -> ?redact:bool
  -> ns:string
  -> name:string
  -> unit
  -> Sol_cli_yaml.document

val external_secret_doc
  :  store_ref:string
  -> store_kind:string
  -> key_prefix:string
  -> refresh_interval:string
  -> secret_keys:string list
  -> ns:string
  -> name:string
  -> Sol_cli_yaml.document

type workload_shape =
  | Http_service
  | Background_worker

val deployment_doc
  :  ?rollout_strategy:Sol_cli_toml.rollout_strategy
  -> ?extra_labels:(string * string) list
  -> ?secret_keys:string list
  -> ?volumes:Sol_cli_toml.volume list
  -> ?env:string
  -> ?availability:Sol_cli_availability.t
  -> ?consumes_kafka:bool
  -> ?readiness_path:string
  -> config_hash:string
  -> shape:workload_shape
  -> replicas:int
  -> cpu:string
  -> memory:string
  -> ns:string
  -> name:string
  -> image:string
  -> workspace:string
  -> domain:string
  -> primitive:string
  -> release_id:Sol_cli_release_id.t
  -> unit
  -> Sol_cli_yaml.document

val rollout_doc
  :  ?extra_labels:(string * string) list
  -> ?secret_keys:string list
  -> ?volumes:Sol_cli_toml.volume list
  -> ?env:string
  -> ?availability:Sol_cli_availability.t
  -> ?consumes_kafka:bool
  -> ?readiness_path:string
  -> config_hash:string
  -> shape:workload_shape
  -> replicas:int
  -> cpu:string
  -> memory:string
  -> ns:string
  -> name:string
  -> image:string
  -> pd:Sol_cli_toml.progressive_delivery
  -> workspace:string
  -> domain:string
  -> primitive:string
  -> release_id:Sol_cli_release_id.t
  -> unit
  -> Sol_cli_yaml.document

val pvc_docs
  :  ns:string
  -> name:string
  -> Sol_cli_toml.volume list
  -> Sol_cli_yaml.document list

val blue_green_service_docs : ns:string -> name:string -> Sol_cli_yaml.document list
val service_doc : ns:string -> name:string -> Sol_cli_yaml.document

val ingress_doc
  :  ?ingress_host:string
  -> ?ingress_path:string
  -> ?cluster_issuer:string
  -> ?tls_secret_name:string
  -> ns:string
  -> name:string
  -> unit
  -> Sol_cli_yaml.document

val network_policy_doc
  :  ?egress_to:(string * string) list
  -> ?ingress_from:(string * string) list
  -> ns:string
  -> name:string
  -> unit
  -> Sol_cli_yaml.document

module Scheduled_workload_spec : sig
  type t =
    { ns : string
    ; name : string
    ; image : string
    ; secret_keys : string list
    ; env : string option
    ; schedule : string
    ; concurrency_policy : string
    ; backoff_limit : int
    ; cpu : string
    ; memory : string
    ; workspace : string
    ; domain : string
    ; release_id : Sol_cli_release_id.t
    }
end

val cronjob_doc : Scheduled_workload_spec.t -> Sol_cli_yaml.document

val migration_configmap_doc
  :  name:string
  -> namespace:string
  -> (string * string) list
  -> Sol_cli_yaml.document

val migration_job_doc
  :  name:string
  -> namespace:string
  -> image:string
  -> args:string list
  -> configmap_name:string
  -> Sol_cli_yaml.document

val create_idempotent
  :  ctx:Sol_cli_kube_destination.context
  -> file:string
  -> (unit, Sol_cli_process.error) result

val apply
  :  ctx:Sol_cli_kube_destination.context
  -> string * string
  -> dry_run:bool
  -> (unit, string) result

val emit_to_dir
  :  string
  -> string * string
  -> ns:string
  -> name:string
  -> (string, string) result
