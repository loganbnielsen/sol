val generated_module : dir:string -> string
val generated_path : dir:string -> string
val render : Sol_cli_toml.event_decl list -> string
val generate : root:string -> check:bool -> (string list, string) result
