type platform_storage =
  { storage_class : string
  ; csi_driver : string
  }

type t =
  { backend_config :
      Sol_cli_config.target
      -> bucket:string
      -> object_key:string
      -> (string list, string) result
  ; cluster_access_role_arn : Sol_cli_config.target -> (string option, string) result
  ; platform_storage : platform_storage
  ; cluster_substrate :
      (outputs_json:string
       -> region:string
       -> cluster_name:string
       -> (Sol_cli_cluster_substrate.t, string) result)
        option
  ; disk_quota :
      (outputs_json:string
       -> region:string
       -> (Sol_cli_disk_quota.observation, string) result)
        option
  ; own_vars :
      Sol_cli_config.target
      -> workspace:string
      -> (string * string) list
      -> (string * string) list
  ; profile_vars : production:bool -> production_postgres:bool -> (string * string) list
  ; guarded_removals : string list
  ; root_declared_vars :
      has_postgres:bool
      -> production_postgres:bool
      -> ecr_repositories:(unit -> (string, string) result)
      -> ((string * string) list, string) result
  ; destroy_guard_vars : final_snapshot:string option -> (string * string) list
  ; bootstrap_matchers : Sol_cli_terraform_plan.matcher list
  ; bootstrap_scope : Sol_cli_terraform.scope
  ; reconciliation_scope : string list -> Sol_cli_terraform.scope
  ; guarded_addresses : string list
  ; cloud_ready_expectation : string
  ; production_qualified : bool
  ; sol_keys : string list
  ; state_locking : string option
  ; scoped_identities : string list
  }

val required : string -> string option -> (string, string) result
val aws : t
val gcp : t
val capabilities_of : Sol_cli_provider.t -> t
