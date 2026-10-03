type t =
  | Aws
  | Gcp
  | Byo

val of_string : string -> t option
val to_string : t -> string
val is_known : string -> bool
val all : t list

type key_disposition =
  | Sol_consumes
  | Passed_to_terraform

type owned_key =
  { key : string
  ; disposition : key_disposition
  }

val owned_keys : t -> owned_key list
val owned_legacy_key : string -> t option
val sol_keys : t -> string list
