type t =
  | Aws
  | Gcp
  | Byo

val of_string : string -> t option
val to_string : t -> string
val is_known : string -> bool
val all : t list
val owned_legacy_key : string -> t option
