(** [subst vars s] replaces every [{{key}}] in [s] with the corresponding value
    from [vars]. Applied left-to-right; earlier bindings win on overlap. *)
val subst : (string * string) list -> string -> string

(** Create [dir] and any missing parent directories, tolerating an
    already-existing directory. Raises [Failure] if a path component exists as a
    non-directory, or if directory creation fails (permission denied, disk full,
    etc.) — never silently proceeds as if it had succeeded. *)
val mkdir_p : string -> unit

val write_file : path:string -> content:string -> unit

(** Create all intermediate directories then write [content] to [path]. Prints "
    created <path>" to stdout. *)
val link_dir : path:string -> target:string -> unit

(** Lowercase and replace hyphens with underscores — safe for OCaml identifiers
    and dune library names. *)
val normalize : string -> string

(** [normalize] then uppercase the first character — produces a valid OCaml
    module name, e.g. "notify_worker" → "Notify_worker". *)
val capitalize_name : string -> string
