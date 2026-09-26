type t =
  | Aws
  | Gcp

val of_string : string -> t option
val to_string : t -> string
val is_known : string -> bool
val all : t list

(** The provider that owns a legacy flat target-file key, if any, so generic config can tell
    one from an unknown key and name the block it belongs in (AUDIT-POST-003). The table
    itself stays private in the implementation; it lives in the provider tier because config
    already depends on it, and see the implementation for why the string-literal form this
    replaced could not be guarded. *)
val owned_legacy_key : string -> t option
