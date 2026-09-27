val confirm_guarded_removal_flag : string

val init
  :  assets:Sol_cli_platform_assets.t
  -> Sol_cli_run_log.t
  -> provider:Sol_cli_provider.t
  -> role:Sol_cli_platform_assets.cloud_role
  -> string list
  -> (unit, Sol_cli_cloud_apply.failure) result

val plan
  :  assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> provider:Sol_cli_provider.t
  -> cloud_target:Sol_cli_cloud_lifecycle.cloud_target
  -> target_cfg:Sol_cli_config.target
  -> infra_dir:string
  -> platform_dir:string
  -> platform_backend:string list
  -> var_files:string list
  -> vars:string list
  -> (unit, Sol_cli_cloud_apply.failure) result

val apply_deps
  :  assets:Sol_cli_platform_assets.t
  -> confirm_ecr_removal:bool
  -> provider:Sol_cli_provider.t
  -> pname:string
  -> run_log:Sol_cli_run_log.t
  -> infra_dir:string
  -> platform_dir:string
  -> platform_backend:string list
  -> var_files:string list
  -> vars:string list
  -> cloud_target:Sol_cli_cloud_lifecycle.cloud_target
  -> target_cfg:Sol_cli_config.target
  -> (Sol_cli_cluster.t, (string * string) list, unit) Sol_cli_cloud_apply.deps

val destroy_preview
  :  assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> provider:Sol_cli_provider.t
  -> cloud_target:Sol_cli_cloud_lifecycle.cloud_target
  -> target_cfg:Sol_cli_config.target
  -> infra_dir:string
  -> var_files:string list
  -> vars:string list
  -> (unit, string) result

val destruction
  :  run_log:Sol_cli_run_log.t
  -> provider:Sol_cli_provider.t
  -> target_cfg:Sol_cli_config.target
  -> infra_dir:string
  -> var_files:string list
  -> vars:string list
  -> Sol_cli_destruction.t

val destroy_deps
  :  assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> provider:Sol_cli_provider.t
  -> cloud_target:Sol_cli_cloud_lifecycle.cloud_target
  -> target_cfg:Sol_cli_config.target
  -> infra_dir:string
  -> cloud_backend:string list
  -> var_files:string list
  -> vars:string list
  -> retention:Sol_cli_cloud_lifecycle.destroy_retention
  -> destruction:Sol_cli_destruction.t
  -> Sol_cli_cloud_destroy.deps
