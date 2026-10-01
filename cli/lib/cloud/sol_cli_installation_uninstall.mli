type plan =
  { removes : Sol_cli_installation.prerequisite list
  ; retains : (string * string) list
  ; unmanages_the_zone : bool
  ; dns_confirmation : string option
  }

val plan
  :  prerequisites:Sol_cli_installation.prerequisite list
  -> zone_in_state:bool
  -> Sol_cli_installation.installation_config
  -> plan

val lines : plan -> string list
val confirmed_dns_zone_matches : confirmation:string option -> domain:string -> bool
val refusal_of_unobservable : string -> string
