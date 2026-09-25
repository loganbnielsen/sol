type t =
  | Aws
  | Gcp

val of_string : string -> t option
val to_string : t -> string
val is_known : string -> bool
val all : t list

(** The target-file keys each provider owns, so generic config can tell a flat legacy key
    from an unknown one and name the block it belongs in (AUDIT-POST-003). It lives in the
    provider tier because config already depends on it; see the implementation for why the
    string-literal form this replaced could not be guarded. *)
val owned_legacy_keys : (string * t) list

val owned_legacy_key : string -> t option
