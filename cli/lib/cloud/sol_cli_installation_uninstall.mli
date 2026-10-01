type plan =
  { removes : Sol_cli_installation.prerequisite list
  ; retains : (string * string) list
  ; unmanages_the_zone : bool
  ; dns_confirmation : string option
  }

val plan
  :  prerequisites:Sol_cli_installation.prerequisite list
  -> created:Sol_cli_installation.prerequisite list
  -> zone_in_state:bool
  -> Sol_cli_installation.installation_config
  -> plan

val lines : plan -> string list
val confirmed_dns_zone_matches : confirmation:string option -> domain:string -> bool
val refusal_of_unobservable : string -> string

type removal_verification =
  { removed : Sol_cli_installation.prerequisite list
  ; present : (Sol_cli_installation.prerequisite * string) list
  ; unknown : (Sol_cli_installation.prerequisite * string) list
  }

val classify_removal
  :  removes:Sol_cli_installation.prerequisite list
  -> (Sol_cli_installation.prerequisite * Sol_cli_installation.verdict) list
  -> removal_verification

val removal_established : removal_verification -> bool
val verification_lines : removal_verification -> string list
