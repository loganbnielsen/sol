type reason =
  | Not_found
  | Other

val says_not_found : ?project:string -> string -> bool
val classify : ?project:string -> Sol_cli_process.error -> reason
val mentioned_projects : string -> string list
