val generated_module : dir:string -> string
val generated_path : dir:string -> language:Sol_cli_toml.binding_language -> string

val render
  :  language:Sol_cli_toml.binding_language
  -> Sol_cli_toml.event_decl list
  -> string

val generate : root:string -> check:bool -> (string list, string) result
