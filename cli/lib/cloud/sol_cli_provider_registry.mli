val of_root
  :  Sol_cli_provider.t
  -> target:Sol_cli_config.target
  -> chdir:string
  -> (Sol_cli_cluster.t option, string) result

val destruction
  :  Sol_cli_provider.t
  -> Sol_cli_destruction.context
  -> Sol_cli_destruction.t

val credentials
  :  Sol_cli_provider.t
  -> operation:string
  -> leaves_target_standing:bool
  -> (unit, string) result
