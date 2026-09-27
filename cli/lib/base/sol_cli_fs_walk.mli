type error =
  | Absent of string
  | Unreadable of string * string

val to_string : error -> string
val entries : string -> (string list, error) result
val dirs : string -> (string list, error) result
val files : string -> (string list, error) result
