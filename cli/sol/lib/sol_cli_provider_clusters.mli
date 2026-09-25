(** REFAC-096: the cluster a provider's cloud root produced, built by that
    provider's module. [Ok None] when the root has published no outputs yet (no
    substrate); an unreadable root is an error, never absence. *)
val of_root
  :  Sol_cli_provider.t
  -> target:Sol_cli_config.target
  -> chdir:string
  -> (Sol_cli_cluster.t option, string) result
