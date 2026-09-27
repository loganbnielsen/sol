type value =
  | Text of string
  | Texts of string list
  | Null

val displayable : string -> ((string * value) list, string) result
val line : string * value -> string
