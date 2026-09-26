(** Small string predicates Sol otherwise spells out by hand (REFAC-121, REFAC-122). *)

(** [is_blank s]: [s] is empty or only whitespace. *)
val is_blank : string -> bool

(** [non_blank s] is [Some (String.trim s)], or [None] when [s] is blank. *)
val non_blank : string -> string option

(** [non_blank_opt o] is [non_blank] under an option: [None], [Some ""] and
    [Some "  "] are all [None]. The usual way to read an optional setting. *)
val non_blank_opt : string option -> string option

(** [non_empty o] is [o] with [Some ""] as [None], and nothing trimmed: for
    values where whitespace is data. *)
val non_empty : string option -> string option

(** [env name] is the environment variable [name], or [None] when it is unset
    or set to [""]. [Unix.putenv] cannot unset, so Sol treats [""] as unset. *)
val env : string -> string option

(** [contains ~needle haystack]: [needle] occurs in [haystack]. The empty needle
    occurs everywhere. *)
val contains : needle:string -> string -> bool
