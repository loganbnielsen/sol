type deployment_mode =
  | Local
  | Customer_cloud
  | Sol_hosted

type env_config =
  { name : string
  ; mode : deployment_mode
  ; registry : string
  ; image_tag : string
  ; env : string option
  ; region : string option
  ; base_domain : string option
  ; cluster_issuer : string
  ; secret_backend : Sol_cli_manifest.secret_backend
  }

type primitive =
  | Svc
  | Worker
  | Fn

type effective_rollout_strategy =
  | Effective_canary
  | Effective_blue_green
  | Effective_recreate
  | Effective_rolling_update

type k8s_name = Sol_cli_kubernetes_name.k8s_name
type namespace = Sol_cli_kubernetes_name.namespace

type service_call =
  { env_var : string
  ; url : string
  ; target_domain : string
  ; target_name : k8s_name
  ; target_namespace : namespace
  }

type service_spec =
  { domain : string
  ; source_name : string
  ; k8s_name : k8s_name
  ; namespace : namespace
  ; primitive : primitive
  ; source_dir : string
  ; image : string
  ; config : (string * string) list
  ; secrets : (string * string) list
  ; build_secret_keys : string list
  ; volumes : Sol_cli_toml.volume list
  ; schedule : string option
  ; scheduled_concurrency : Sol_cli_toml.scheduled_concurrency
  ; backoff_limit : int
  ; replicas : int
  ; availability : Sol_cli_availability.t
  ; consumes_kafka : bool
  ; language : Sol_cli_compat.language option
  ; cpu : Sol_cli_toml.cpu_quantity
  ; memory : Sol_cli_toml.memory_quantity
  ; rollout_strategy : Sol_cli_toml.rollout_strategy option
  ; ingress_host : Sol_cli_toml.hostname option
  ; ingress_path : Sol_cli_toml.ingress_path option
  ; cluster_issuer : string
  ; calls : service_call list
  ; called_by : service_call list
  ; extra_labels : (string * string) list
  ; progressive_delivery : Sol_cli_toml.progressive_delivery option
  }

type profile_claim =
  { profile : Sol_cli_profile.t
  ; requirements : Sol_cli_profile.capability list
  ; application_findings : (Sol_cli_profile.capability * string) list
  }

type t =
  { workspace : string
  ; release_id : Sol_cli_release_id.t
  ; environment : env_config
  ; services : service_spec list
  ; topics : Sol_cli_plan_ids.Topic_name.t list
  ; migrations : Sol_cli_plan_ids.Migration_file.t list
  ; schema_subjects : Sol_cli_plan_ids.Schema_subject.t list
  ; consumer_groups : Sol_cli_plan_ids.Consumer_group.t list
  ; requested_scope : string
  ; profile : profile_claim option
  }

type plan_error =
  | Toml_error of Sol_cli_toml.parse_error
  | Invalid_persistence of
      { workload : string
      ; message : string
      }
  | Unsupported_availability of
      { workload : string
      ; message : string
      }
  | Invalid_service_call of
      { service : string
      ; ref : string
      ; message : string
      }
  | Invalid_kubernetes_name of
      { field : string
      ; value : string
      ; message : string
      }

val derive_consumer_groups
  :  ?declared:Sol_cli_config.declared
  -> string
  -> service_spec list
  -> Sol_cli_plan_ids.Consumer_group.t list

val mode_to_string : deployment_mode -> string
val primitive_to_string : primitive -> string
val primitive_of_string : string -> (primitive, string) result
val effective_rollout_strategy : service_spec -> effective_rollout_strategy
val effective_rollout_strategy_to_string : effective_rollout_strategy -> string
val release_workload_of_spec : service_spec -> Sol_cli_release_id.workload
val to_json : t -> Yojson.Safe.t
val pp_summary : Format.formatter -> t -> unit
val is_whole_workspace : t -> bool
val plan_error_to_string : plan_error -> string
val validate_persistence : service_spec -> (unit, plan_error) result
val validate_availability : service_spec -> (unit, plan_error) result
val k8s_name_result : string -> (k8s_name, plan_error) result
val k8s_name_to_string : k8s_name -> string
val namespace_result : workspace:string -> domain:string -> (namespace, plan_error) result
val namespace_to_string : namespace -> string
val namespace_name : workspace:string -> domain:string -> (string, string) result
val k8s_name : string -> (string, string) result

val image_ref
  :  registry:string
  -> workspace:string
  -> k8s_name:k8s_name
  -> tag:string
  -> string

val of_services_result
  :  workspace:string
  -> env:env_config
  -> facts:Sol_cli_workspace_model.t
  -> ?requested_scope:string
  -> ?declared:Sol_cli_config.declared
  -> ?image_refs:(string * string) list
  -> ?inventory:Sol_cli_manifest.service list
  -> Sol_cli_manifest.service list
  -> (t, plan_error) result
