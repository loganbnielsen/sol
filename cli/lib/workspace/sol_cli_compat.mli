type language =
  | Ocaml
  | Typescript

val all : language list
val to_string : language -> string
val of_string : string -> (language, string) result
val supported_by_profile : Sol_cli_profile.t -> language list
val is_supported_by_profile : Sol_cli_profile.t -> language -> bool
