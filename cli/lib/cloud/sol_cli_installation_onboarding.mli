type state =
  | Present
  | Absent
  | Partial
  | Indeterminate

type decision =
  | Proceed
  | Offer
  | Refuse
  | Report

val state_of_verdicts
  :  (Sol_cli_installation.prerequisite * Sol_cli_installation.verdict) list
  -> state

val decision : interactive:bool -> state -> decision

val report_lines
  :  target:string
  -> configuration:Sol_cli_installation.installation_config
  -> (Sol_cli_installation.prerequisite * Sol_cli_installation.verdict) list
  -> string list

val refusal_lines
  :  target:string
  -> because:string
  -> (Sol_cli_installation.prerequisite * Sol_cli_installation.verdict) list
  -> string list

val still_unresolved_lines
  :  target:string
  -> (Sol_cli_installation.prerequisite * Sol_cli_installation.verdict) list
  -> string list

val undeclared_lines : target:string -> reason:string -> string list

val indeterminate_lines
  :  target:string
  -> (Sol_cli_installation.prerequisite * Sol_cli_installation.verdict) list
  -> string list

val observed_lines : target:string -> string list
val present_lines : target:string -> string list
val established_lines : target:string -> string list
