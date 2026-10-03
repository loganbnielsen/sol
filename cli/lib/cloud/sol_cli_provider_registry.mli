type resolution_failure =
  | Outputs_unreadable of string
  | State_unreadable of string
  | No_root of string

val resolution_failure_to_string : resolution_failure -> string

val of_root
  :  Sol_cli_provider.t
  -> target:Sol_cli_config.target
  -> chdir:string
  -> (Sol_cli_cluster.t option, resolution_failure) result

val destruction
  :  Sol_cli_provider.t
  -> Sol_cli_destruction.context
  -> Sol_cli_destruction.t

val observations
  :  Sol_cli_provider.t
  -> Sol_cli_config.target
  -> cluster_name:string
  -> Sol_cli_absence.observation list

val substrate_absence
  :  Sol_cli_provider.t
  -> Sol_cli_config.target
  -> cluster_name:string
  -> Sol_cli_absence.observation

val resource_identity
  :  Sol_cli_provider.t
  -> cluster_name:string
  -> Sol_cli_resource_identity.entry list

val credentials
  :  Sol_cli_provider.t
  -> operation:string
  -> leaves_target_standing:bool
  -> (unit, string) result
