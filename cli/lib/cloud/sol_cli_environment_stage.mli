type failure =
  | Terraform_failed of string
  | Refused of string

val failure_to_string : failure -> string

type environment =
  { cluster : Sol_cli_cluster.t option
  ; infra_dir : string
  }

type outcome =
  | Applied of environment
  | Apply_failed of
      { failure : failure
      ; cleanup : Sol_cli_cloud_destroy.cleanup
      }

val plan
  :  assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> target:string
  -> var_file:string option
  -> vars:string list
  -> unit
  -> (unit, failure) result

val apply
  :  ?confirm_ecr_removal:bool
  -> ?accept_unresolved:bool
  -> assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> target:string
  -> var_file:string option
  -> vars:string list
  -> unit
  -> (outcome, failure) result

val reconcile_ownership_at
  :  provider:Sol_cli_provider.t
  -> target_cfg:Sol_cli_config.target
  -> infra_dir:string
  -> var_files:string list
  -> vars:string list
  -> unit
