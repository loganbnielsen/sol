val subst : (string * string) list -> string -> string
(** [subst vars s] replaces every [{{key}}] in [s] with the corresponding
    value from [vars]. Applied left-to-right; earlier bindings win on overlap. *)

val mkdir_p : string -> unit
(** Create [dir] and any missing parent directories, tolerating an
    already-existing directory. Raises [Failure] if a path component exists
    as a non-directory, or if directory creation fails (permission denied,
    disk full, etc.) — never silently proceeds as if it had succeeded. *)

val write_file : path:string -> content:string -> unit

val link_dir : path:string -> target:string -> unit
(** Create all intermediate directories then write [content] to [path].
    Prints "  created  <path>" to stdout. *)

val normalize : string -> string
(** Lowercase and replace hyphens with underscores — safe for OCaml identifiers
    and dune library names. *)

val capitalize_name : string -> string
(** [normalize] then uppercase the first character — produces a valid OCaml
    module name, e.g. "notify_worker" → "Notify_worker". *)
