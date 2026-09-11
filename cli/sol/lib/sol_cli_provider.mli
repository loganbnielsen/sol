type t =
  | Aws
  | Gcp

val of_string : string -> t option
val to_string : t -> string
val is_known : string -> bool
