val generated_module : dir:string -> string
val generated_path : dir:string -> language:Sol_cli_toml.binding_language -> string

val render
  :  language:Sol_cli_toml.binding_language
  -> Sol_cli_toml.event_decl list
  -> string

type projection_issue =
  | Stale of string
  | Missing of string

val check_freshness : root:string -> (projection_issue list, string) result
val generate : root:string -> check:bool -> (string list, string) result
