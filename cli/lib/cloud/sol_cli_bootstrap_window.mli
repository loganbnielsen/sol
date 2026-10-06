val bootstrap_only : Sol_cli_capability.capability list
val successor : Sol_cli_capability.capability list

val can_i
  :  run:(string list -> (Sol_cli_process.output, Sol_cli_process.error) result)
  -> Sol_cli_capability.capability
  -> Sol_cli_capability.capability_answer

val probe
  :  run:(string list -> (Sol_cli_process.output, Sol_cli_process.error) result)
  -> Sol_cli_capability.capability list
  -> (Sol_cli_capability.capability * Sol_cli_capability.capability_answer) list

val permitted
  :  (Sol_cli_capability.capability * Sol_cli_capability.capability_answer) list
  -> bool

val indeterminate
  :  (Sol_cli_capability.capability * Sol_cli_capability.capability_answer) list
  -> (string * string) list

val control_failure : permitted:bool -> (string * string) list -> string
