val observations
  :  Sol_cli_config.target
  -> cluster_name:string
  -> Sol_cli_absence.observation list

val class_names : string list

val relinquished_residue_probes : (string * string) list
val unresolved : reason:string -> Sol_cli_absence.observation list
