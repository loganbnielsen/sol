(** [subst vars s] replaces every [{{key}}] in [s] with the corresponding value
    from [vars]. Applied left-to-right; earlier bindings win on overlap. *)
val subst : (string * string) list -> string -> string

(** Create the intermediate directories, write [content] to [path], and report
    "  created <path>". A failure names the path (REFAC-134). *)
val write_file : path:string -> content:string -> (unit, string) result

(** Lowercase and replace hyphens with underscores — safe for OCaml identifiers
    and dune library names. *)
val normalize : string -> string

(** [normalize] then uppercase the first character — produces a valid OCaml
    module name, e.g. "notify_worker" → "Notify_worker". *)
val capitalize_name : string -> string
