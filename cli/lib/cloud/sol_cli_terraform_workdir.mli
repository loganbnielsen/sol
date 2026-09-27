val dir
  :  provider:Sol_cli_provider.t
  -> role:Sol_cli_platform_assets.cloud_role
  -> backend_config:string list
  -> string

val chdir
  :  provider:Sol_cli_provider.t
  -> role:Sol_cli_platform_assets.cloud_role
  -> backend_config:string list
  -> string

val is_runtime_artifact : string -> bool

val materialize
  :  assets:Sol_cli_platform_assets.t
  -> provider:Sol_cli_provider.t
  -> role:Sol_cli_platform_assets.cloud_role
  -> backend_config:string list
  -> (string, string) result
